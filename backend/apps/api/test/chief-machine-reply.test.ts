import { runInDurableObject } from "cloudflare:test"
import type { Principal } from "@cmux/ownership"
import { describe, expect, it, vi } from "vitest"
import { chiefPrincipal } from "../src/chief-brain/brain-io.ts"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import { writeConfig } from "../src/chief-brain/brain-store.ts"
import type { Env } from "../src/env.ts"
import { convId, objectIdOf, result, sha, signIn, stub, testEnv, urlFor, worker } from "./home-attachments-support.ts"

type MessagePart = { type: string; text?: string; hash?: string; byte_count?: number; [key: string]: unknown }
type Fixture = {
  readonly messageSubmits: Array<{ key: string; parts: Array<MessagePart> }>
  quotaCalls: number
  putCalls: number
  failStorage: boolean
  lostResponse: boolean
  finish: ReturnType<typeof vi.fn<() => void>>
}

const textPart = (parts: ReadonlyArray<MessagePart>) => parts.find((part) => part.type === "text")?.text ?? ""
const attachmentPart = (parts: ReadonlyArray<MessagePart>) => parts.find((part) => part.type === "attachment")

/**
 * A real ConversationDO and UserDO sit behind the brain. Only the message-send response is wrapped so
 * this test can model an acknowledged write whose response disappears; all membership, quota, slots,
 * upload verification and R2 reads use the production handlers and reducers.
 */
const withReply = async (suffix: string, reply: string, check: (b: ChiefBrainDO, run: string, conversation: string, owner: Awaited<ReturnType<typeof signIn>>, f: Fixture) => Promise<void>) => {
  const owner = await signIn(`chief-reply-${suffix}`)
  const conversation = convId()
  const agent = `agent_reply_${suffix}`
  const chiefOwner = { ...owner.principal, owned_agents: [{ id: agent, display_name: "Chief" }] } as Principal
  const conversationStub = stub(testEnv.CONVERSATION_DO, conversation)
  expect(result(await conversationStub.submit(conversation, chiefOwner, {
    t: "op",
    op: "conversation.create",
    params: {
      id: conversation,
      kind: "group",
      title: "Chief reply",
      participants: [
        { id: owner.user, kind: "human", display_name: "Owner" },
        { id: agent, kind: "agent", display_name: "Chief", agent_class: "mux" }
      ]
    },
    idempotency_key: "create"
  }))).toMatchObject({ t: "result" })

  const f: Fixture = { messageSubmits: [], quotaCalls: 0, putCalls: 0, failStorage: false, lostResponse: false, finish: vi.fn() }
  const realConversation = testEnv.CONVERSATION_DO
  const realUsers = testEnv.USER_DO
  const realBucket = testEnv.HOME_ATTACHMENTS
  const conversationNs = {
    idFromName: realConversation.idFromName.bind(realConversation),
    get: (name: Parameters<typeof realConversation.get>[0]) => {
      const raw = realConversation.get(name)
      return new Proxy(raw, {
        get(target, property, receiver) {
          if (property === "submit") return async (entity: string, principal: Principal, frame: { op?: string; idempotency_key?: string; params?: { parts?: Array<MessagePart>; client_msg_id?: string } }) => {
            const response = await (target as unknown as { submit: (entity: string, principal: Principal, frame: unknown) => Promise<{ frames: Array<{ t: string; code?: string }> }> }).submit(entity, principal, frame)
            if (frame.op === "message.send") {
              const parts = (frame.params?.parts ?? []) as Array<MessagePart>
              f.messageSubmits.push({ key: frame.idempotency_key ?? frame.params?.client_msg_id ?? "", parts })
              if (f.lostResponse && result(response)?.t === "result") {
                f.lostResponse = false
                throw new Error("response lost after message.send committed")
              }
            }
            return response
          }
          const value = Reflect.get(target, property, receiver)
          return typeof value === "function" ? (...args: unknown[]) => Reflect.apply(value, target, args) : value
        }
      })
    }
  } as unknown as Env["CONVERSATION_DO"]
  const userNs = {
    idFromName: realUsers.idFromName.bind(realUsers),
    get: (name: Parameters<typeof realUsers.get>[0]) => {
      const raw = realUsers.get(name)
      return new Proxy(raw, {
        get(target, property, receiver) {
          if (property === "takeAttachmentQuota") return async (...args: unknown[]) => {
            f.quotaCalls++
            return (target as unknown as { takeAttachmentQuota: (...a: unknown[]) => Promise<unknown> }).takeAttachmentQuota(...args)
          }
          const value = Reflect.get(target, property, receiver)
          return typeof value === "function" ? (...args: unknown[]) => Reflect.apply(value, target, args) : value
        }
      })
    }
  } as unknown as Env["USER_DO"]
  const bucket = new Proxy(realBucket, {
    get(target, property, receiver) {
      if (property === "put") return async (...args: unknown[]) => {
        f.putCalls++
        if (f.failStorage) {
          f.failStorage = false
          throw new Error("temporary R2 failure")
        }
        return (target as unknown as { put: (...a: unknown[]) => Promise<unknown> }).put(...args)
      }
      const value = Reflect.get(target, property, receiver)
      return typeof value === "function" ? (...args: unknown[]) => Reflect.apply(value, target, args) : value
    }
  })
  const fake = { ...testEnv, CONVERSATION_DO: conversationNs, USER_DO: userNs, HOME_ATTACHMENTS: bucket } as unknown as Env

  const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${agent}/${conversation}`))
  const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (b: ChiefBrainDO) => Promise<T>) => Promise<T>
  await inDO(brain, async (b) => {
    const object = b as unknown as { doEnv: Env }
    const previous = object.doEnv
    object.doEnv = fake
    const binding = { workspace: `chief-default-${owner.user}`, team: owner.principal.team!, machine: "machine_reply", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_reply" }
    const route = { binding, harness: "claude" as const }
    const run = `run_reply_${suffix}`
    writeConfig(b.sql, { owner: owner.user, agent, enabled: "1", machine_route: JSON.stringify(route) })
    b.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, last_seq, effect_authorized, status, model, started, ended, reply, post) VALUES (?, ?, 'original', 'chief', 1, 1, 'done', 'machine:claude', ?, ?, ?, 'pending')`, run, conversation, Date.now() - 1, Date.now(), reply)
    const admission = vi.spyOn(b, "admitted").mockImplementation(async () => ({ ok: true, config: b.config(), machine: route }))
    const finish = vi.spyOn(b, "finish").mockImplementation(async () => { f.finish() })
    const announce = vi.spyOn(b, "announce").mockImplementation(() => undefined)
    try { await check(b, run, conversation, owner, f) } finally {
      object.doEnv = previous
      admission.mockRestore()
      finish.mockRestore()
      announce.mockRestore()
    }
  })
}

const longReply = "🧪漢字e\u0301\n".repeat(30_000) + "\n[Open the built page](https://hello.example.test/final-tail-url)"
const bytes = new TextEncoder().encode(longReply)
const posted = (b: ChiefBrainDO, run: string) => b.sql.exec<{ post: string; reply: string | null }>(`SELECT post, reply FROM cb_turn WHERE id = ?`, run).one()

describe("complete machine replies through durable attachments", { timeout: 120_000 }, () => {
  it("stores a >6-turn Unicode reply as one verified attachment and keeps the tail URL in the compact message", async () => {
    expect(bytes.byteLength).toBeGreaterThan(6 * 60 * 1024)
    await withReply("success", longReply, async (b, run, conversation, owner, f) => {
      expect(await b.post(run)).toBeNull()
      expect(f.messageSubmits).toHaveLength(1)
      const sent = f.messageSubmits[0]!
      expect(sent.parts).toHaveLength(3)
      expect(textPart(sent.parts)).toContain("https://hello.example.test/final-tail-url")
      expect(new TextEncoder().encode(textPart(sent.parts)).byteLength).toBeLessThanOrEqual(60 * 1024)
      expect(attachmentPart(sent.parts)).toMatchObject({ type: "attachment", mime_type: "text/plain", byte_count: bytes.byteLength, hash: sha(bytes) })
      expect(posted(b, run).post).toBe("posted")
      expect(f.quotaCalls).toBe(1)
      expect(f.putCalls).toBe(1)

      const minted = await urlFor(owner, conversation, sha(bytes))
      expect(minted.status).toBe(200)
      const downloaded = await worker.fetch(minted.json.value.url)
      expect(downloaded.status).toBe(200)
      const readback = new Uint8Array(await downloaded.arrayBuffer())
      expect(sha(readback)).toBe(sha(bytes))
      expect(new TextDecoder().decode(readback)).toBe(longReply)
      expect(objectIdOf(minted.json.value.url)).toBeTruthy()
    })
  })

  it("retries a lost message-send response with the original key and does not re-upload or duplicate the message", async () => {
    await withReply("lost", longReply, async (b, run, conversation, owner, f) => {
      f.lostResponse = true
      expect(await b.post(run)).not.toBeNull()
      expect(posted(b, run).post).toBe("pending")
      expect(f.messageSubmits).toHaveLength(1)
      const key = f.messageSubmits[0]!.key
      expect(await b.post(run)).toBeNull()
      expect(f.messageSubmits).toHaveLength(2)
      expect(f.messageSubmits[1]!.key).toBe(key)
      expect(f.quotaCalls).toBe(1)
      expect(f.putCalls).toBe(1)
      const conv = testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation)) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<{ ok: boolean; value?: { rows?: { rows: Array<{ row: { author: string } }> } } }> }
      const snapshot = await conv.readOp(conversation, owner.principal, "conversation.snapshot", { tail: 20 })
      expect(snapshot.ok).toBe(true)
      expect(snapshot.value?.rows?.rows.filter((row) => row.row.author === "agent_reply_lost")).toHaveLength(1)
    })
  })

  it("leaves the full reply pending on quota refusal, then recovers without truncating it", async () => {
    await withReply("quota", longReply, async (b, run, conversation, owner, f) => {
      const user = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(owner.user)) as unknown as {
        recordAttachmentStorage(e: string, key: string, size: number): Promise<void>
        releaseAttachmentStorage(e: string, key: string): Promise<void>
      }
      const prior = `home/v1/${conversation}/prior`
      await user.recordAttachmentStorage(owner.user, prior, 10_000_000_000)
      expect(await b.post(run)).not.toBeNull()
      expect(posted(b, run)).toMatchObject({ post: "pending", reply: longReply })
      expect(f.messageSubmits).toHaveLength(0)
      expect(f.finish).not.toHaveBeenCalled()
      await user.releaseAttachmentStorage(owner.user, prior)
      expect(await b.post(run)).toBeNull()
      expect(posted(b, run).post).toBe("posted")
      expect(f.messageSubmits).toHaveLength(1)
      expect(f.quotaCalls).toBe(2)
      expect(f.putCalls).toBe(1)
    })
  })

  it("leaves the full reply pending on storage refusal, retains the result across a failed slot, then recovers", async () => {
    await withReply("storage", longReply, async (b, run, _conversation, _owner, f) => {
      f.failStorage = true
      expect(await b.post(run)).not.toBeNull()
      expect(posted(b, run)).toMatchObject({ post: "pending", reply: longReply })
      expect(f.messageSubmits).toHaveLength(0)
      expect(f.finish).not.toHaveBeenCalled()
      expect(await b.post(run)).toBeNull()
      expect(posted(b, run).post).toBe("posted")
      expect(f.messageSubmits).toHaveLength(1)
      expect(f.quotaCalls).toBe(2)
      expect(f.putCalls).toBe(2)
    })
  })


  it("does not upload or post when turn admission has been revoked", async () => {
    await withReply("revoked", longReply, async (b, run, _conversation, _owner, f) => {
      await b.post(run, Promise.resolve({ ok: false, reason: "chief.archived" }))
      expect(f.quotaCalls).toBe(0)
      expect(f.putCalls).toBe(0)
      expect(f.messageSubmits).toHaveLength(0)
    })
  })

  it("does not upload through a removed Chief's former conversation membership", async () => {
    await withReply("removed", longReply, async (b, run, conversation, owner, f) => {
      const conv = stub(testEnv.CONVERSATION_DO, conversation)
      expect(result(await conv.submit(conversation, owner.principal, {
        t: "op", op: "participants.remove", params: { participant: "agent_reply_removed" }, idempotency_key: "remove"
      }))).toMatchObject({ t: "result" })
      expect(await b.post(run)).toBeNull()
      expect(posted(b, run)).toMatchObject({ post: "refused", reply: longReply })
      expect(f.quotaCalls).toBe(0)
      expect(f.putCalls).toBe(0)
      expect(f.messageSubmits).toHaveLength(0)
    })
  })

  it("keeps the actual conversation's agent-turn budget on the compact message", async () => {
    await withReply("budget", longReply, async (b, run, conversation, owner, f) => {
      const conv = stub(testEnv.CONVERSATION_DO, conversation)
      expect(result(await conv.submit(conversation, owner.principal, {
        t: "op", op: "conversation.settings.set", params: { agent_budget: { turns: 1, gap_ms: 0 } }, idempotency_key: "budget"
      }))).toMatchObject({ t: "result" })
      expect(result(await conv.submit(conversation, chiefPrincipal("agent_reply_budget", owner.user), {
        t: "op", op: "message.send", params: { client_msg_id: "prior", parts: [{ type: "text", text: "prior answer" }] }, idempotency_key: "prior"
      }))).toMatchObject({ t: "result" })
      expect(await b.post(run)).toBeNull()
      expect(b.sql.exec<{ post: string; reason: string }>(`SELECT post, reason FROM cb_turn WHERE id = ?`, run).one()).toMatchObject({ post: "refused", reason: "agent_budget" })
      expect(f.messageSubmits).toHaveLength(1)
      const snapshot = await (testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(conversation)) as unknown as { readOp(e: string, p: Principal, op: string, params: unknown): Promise<{ value?: { rows?: { rows: Array<unknown> } } }> }).readOp(conversation, owner.principal, "conversation.snapshot", { tail: 20 })
      expect(snapshot.value?.rows?.rows).toHaveLength(1)
    })
  })
})
