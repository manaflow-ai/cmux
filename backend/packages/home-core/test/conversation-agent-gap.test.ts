import { describe, expect, it } from "vitest"
import { create } from "../src/conversation/create.ts"
import { MIN_AGENT_GAP_MS } from "../src/conversation/budget.ts"
import { agent, CoreHost, human, NOW, text } from "./support/harness.ts"
import { ALICE, BOB, CHIEF, groupHead } from "./support/cloud.ts"

/**
 * The loop guard's gap between agent texts must not serialize the Chiefs answering one person: in a
 * group with two Chiefs (wake policy "all", or both mentioned) each answers the person's message as
 * soon as its reply is ready. Agent-to-agent traffic after that first round keeps the gap.
 */
const BOBCHIEF = "agent_bobchief"
const send = (host: CoreHost, actor: string, key: string, body: string, threadRoot?: string) =>
  host.run(actor, key, { kind: "message.send", client_msg_id: key, parts: [text(body)], ...(threadRoot ? { thread_root: threadRoot } : {}) })
const code = (r: ReturnType<typeof send>) => (r.ok ? "commit" : r.code)

const cloudGroup = () => new CoreHost(groupHead({ participants: [human(ALICE, "Alice"), human(BOB, "Bob"), agent(CHIEF, ALICE), agent(BOBCHIEF, BOB)] }))
const localGroup = () => {
  const r = create({ id: "conv_TEST", actor: "user_local", title: "mux", participants: [human("user_local"), agent("agent_a"), agent("agent_b")], now: NOW })
  if (!r.ok) throw new Error(r.code)
  return new CoreHost(r.head)
}

describe("agent gap: Chiefs answer one person in parallel", () => {
  for (const [name, make, person, a, b] of [
    ["cloud group", cloudGroup, BOB, CHIEF, BOBCHIEF],
    ["local head", localGroup, "user_local", "agent_a", "agent_b"]
  ] as const) {
    it(`${name}: the second Chief's answer to the person is not held for the gap`, () => {
      const host = make()
      send(host, person, "h1", "status?")
      host.advance(300)
      expect(code(send(host, a, "a1", "fine"))).toBe("commit")
      host.advance(50)
      expect(code(send(host, b, "b1", "also fine"))).toBe("commit")
    })

    it(`${name}: after every Chief answered, agent texts keep the gap (loop guard)`, () => {
      const host = make()
      send(host, person, "h1", "status?")
      expect(code(send(host, a, "a1", "fine"))).toBe("commit")
      expect(code(send(host, b, "b1", "also fine"))).toBe("commit")
      host.advance(MIN_AGENT_GAP_MS - 1)
      expect(code(send(host, a, "a2", "re: also fine"))).toBe("agent_rate")
      host.advance(1)
      expect(code(send(host, a, "a2", "re: also fine"))).toBe("commit")
    })

    it(`${name}: one Chief sending twice right after the person still waits the gap once the round is used`, () => {
      const host = make()
      send(host, person, "h1", "status?")
      expect(code(send(host, a, "a1", "one"))).toBe("commit")
      expect(code(send(host, a, "a2", "two"))).toBe("commit")
      // Two agent texts since the person: the round (one per agent) is spent.
      expect(code(send(host, b, "b1", "three"))).toBe("agent_rate")
    })
  }

  it("a thread's first round is free while the top level's loop is spaced", () => {
    const host = cloudGroup()
    const root = send(host, BOB, "h1", "root")
    if (!root.ok) throw new Error(root.code)
    const rootId = root.commit.message!.id
    expect(code(send(host, CHIEF, "a1", "top"))).toBe("commit")
    expect(code(send(host, BOBCHIEF, "b1", "top"))).toBe("commit")
    expect(code(send(host, CHIEF, "a2", "top again"))).toBe("agent_rate")
    host.advance(10)
    send(host, ALICE, "h2", "in the thread", rootId)
    expect(code(send(host, CHIEF, "a3", "thread answer", rootId))).toBe("commit")
    expect(code(send(host, BOBCHIEF, "b3", "thread answer", rootId))).toBe("commit")
  })

  it("a Chief that left does not widen the round", () => {
    const host = cloudGroup()
    expect(host.run(BOB, "r1", { kind: "participants.remove", participant: BOBCHIEF }).ok).toBe(true)
    send(host, BOB, "h1", "status?")
    expect(code(send(host, CHIEF, "a1", "one"))).toBe("commit")
    expect(code(send(host, CHIEF, "a2", "two"))).toBe("agent_rate")
  })
})
