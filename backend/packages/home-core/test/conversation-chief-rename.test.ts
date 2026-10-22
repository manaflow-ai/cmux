import { describe, expect, it } from "vitest"
import { makeConversationDomain, type ConversationParams, type ConversationState } from "../src/conversation/domain.ts"
import type { Principal } from "../src/conversation/engine-types.ts"
import type { ConversationHead } from "../src/conversation/types.ts"
import { DomainHost } from "./support/harness.ts"
import { as, Group } from "./support/group.ts"

/**
 * A cloud Chief's name lives in its UserDO record (`chief.update {display_name}`) and in its main
 * conversation: the title and the Chief participant's display name. The rename reaches the
 * conversation as `chief.rename`, a system op from the owner's UserDO outbox. Before it, the
 * conversation kept the name the Chief was created with, and the Mac's rename (`title.set` on a
 * chief conversation) was refused with `kind_forbids`, so a cloud Chief could not be renamed.
 */
const OWNER = "user_owner"
const CHIEF = "agent_01ARZ3NDEKTSV4RRFFQ69G5FAV"
const SYSTEM: Principal = { kind: "system", identity: "system:user" }

const chiefConversation = () => {
  const host = new DomainHost<ConversationState, ConversationParams>(makeConversationDomain())
  const made = host.run(SYSTEM, "conversation.create", {
    id: "conv_CHIEFMAIN",
    kind: "chief",
    owner: OWNER,
    title: "Chief",
    participants: [
      { id: OWNER, kind: "human", display_name: "Owner" },
      { id: CHIEF, kind: "agent", agent_class: "mux", owner_user: OWNER, display_name: "Chief" }
    ]
  } as ConversationParams, "create")
  if (!made.ok) throw new Error(`create: ${made.code}`)
  return host
}

const head = (host: DomainHost<ConversationState, ConversationParams>) => host.state as ConversationHead

describe("chief.rename", () => {
  it("the owner's UserDO renames the Chief: the title and the Chief's own name", () => {
    const host = chiefConversation()
    const before = head(host).rev
    const result = host.run(SYSTEM, "chief.rename", { chief: CHIEF, display_name: "Ada" } as ConversationParams, "rename-1")
    expect(result.ok).toBe(true)
    expect(head(host).title).toBe("Ada")
    expect(head(host).participants.find((p) => p.id === CHIEF)?.display_name).toBe("Ada")
    expect(head(host).rev).toBe(before + 1)
    // The owner's inbox learns the new title (an inbox.bump to the human participant).
    expect(host.outbox.some((item) => item.kind === "inbox.bump" && (item.payload as { user?: string }).user === OWNER)).toBe(true)
  })

  it("nobody but the system renames a Chief this way", () => {
    const host = chiefConversation()
    const result = host.run(as(OWNER), "chief.rename", { chief: CHIEF, display_name: "Ada" } as ConversationParams, "rename-user")
    expect(result.ok).toBe(false)
    expect(head(host).title).toBe("Chief")
  })

  it("names only the conversation's own Chief, with a valid name", () => {
    const host = chiefConversation()
    expect(host.run(SYSTEM, "chief.rename", { chief: "agent_01BX5ZZKBKACTAV9WEVGEMMVRZ", display_name: "Ada" } as ConversationParams, "other")).toMatchObject({ ok: false })
    expect(host.run(SYSTEM, "chief.rename", { chief: CHIEF, display_name: "" } as ConversationParams, "blank")).toMatchObject({ ok: false })
    expect(head(host).title).toBe("Chief")
  })

  it("a group is never renamed as a Chief", () => {
    const group = new Group("user_ann", ["user_ben"])
    const result = group.host.run(SYSTEM, "chief.rename", { chief: "user_ben", display_name: "Ada" } as ConversationParams, "group")
    expect(result).toMatchObject({ ok: false, code: "kind_forbids" })
  })
})
