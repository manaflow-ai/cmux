import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"
import { validateParts } from "../../../packages/home-core/src/conversation/validate.ts"
import { MAX_TEXT_BYTES, type Part } from "../../../packages/home-core/src/conversation/types.ts"
import type { ChiefBrainDO } from "../src/chief-brain/brain-do.ts"
import { writeConfig } from "../src/chief-brain/brain-store.ts"
import type { Env } from "../src/env.ts"

type Sent = { key: string; text: string; parts: ReadonlyArray<Part> }
type Frame = { t: "op"; op: string; idempotency_key: string; params: { parts: unknown; client_msg_id: string } }
type Fixture = { attempts: Array<Sent>; messages: Array<Sent>; finish: ReturnType<typeof vi.fn>; loseAt: number; refuseAt: number }
const textOf = (parts: ReadonlyArray<Part>) => parts.flatMap((p) => p.type === "text" ? [p.text] : []).join("")

/** Actual brain-turn.post + postReply, real DO SQL, and the product's message-parts validator. */
const withReply = async (suffix: string, reply: string, check: (b: ChiefBrainDO, run: string, f: Fixture) => Promise<void>) => {
  const testEnv = env as unknown as Env
  const agent = `agent_reply_${suffix}`, owner = `user_reply_${suffix}`, run = "run_reply"
  const stub = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${agent}/reply`))
  const f: Fixture = { attempts: [], messages: [], finish: vi.fn(), loseAt: 0, refuseAt: 0 }
  const ledger = new Map<string, { frames: Array<unknown> }>()
  const fake = {
    ...testEnv,
    CONVERSATION_DO: { idFromName: (x: string) => x, get: () => ({ submit: async (_entity: string, _principal: unknown, frame: Frame) => {
      expect(frame.op).toBe("message.send")
      expect(frame.params.client_msg_id).toBe(frame.idempotency_key)
      // A too-large real message is rejected here rather than accepted by an oversized mock.
      const parts = validateParts(frame.params.parts, true)
      const sent = { key: frame.idempotency_key, parts, text: textOf(parts) }
      expect(new TextEncoder().encode(sent.text).length).toBeLessThanOrEqual(MAX_TEXT_BYTES)
      expect(sent.text).not.toContain("\ufffd")
      expect(new TextDecoder().decode(new TextEncoder().encode(sent.text))).toBe(sent.text)
      f.attempts.push(sent)
      const prior = ledger.get(sent.key)
      if (prior) return prior
      if (f.refuseAt === f.messages.length + 1) {
        f.refuseAt = 0
        const rejected = { frames: [{ t: "reject", code: "agent_rate", message: "retry after the conversation gap" }] }
        ledger.set(sent.key, rejected)
        return rejected
      }
      f.messages.push(sent)
      const accepted = { frames: [{ t: "result", value: { message_id: `message_${f.messages.length}`, seq: f.messages.length } }] }
      ledger.set(sent.key, accepted)
      if (f.loseAt === f.messages.length) {
        f.loseAt = 0
        throw new Error("response lost after message.send committed")
      }
      return accepted
    } }) },
  } as unknown as Env
  const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (b: ChiefBrainDO) => Promise<T>) => Promise<T>
  await inDO(stub, async (b) => {
    const object = b as unknown as { doEnv: Env }, previous = object.doEnv
    object.doEnv = fake
    const binding = { workspace: `chief-default-${owner}`, team: "team_reply", machine: "machine_reply", provider: "freestyle", connection_machine: "vm_abcdefghijklmnopqrst", install: "inst_reply" }
    const route = { binding, harness: "claude" as const }
    writeConfig(b.sql, { owner, agent, enabled: "1", machine_route: JSON.stringify(route) })
    b.sql.exec(`INSERT INTO cb_turn (id, conversation, trigger_message, trigger_kind, last_seq, effect_authorized, status, model, started, ended, reply, post) VALUES (?, 'reply', 'original', 'chief', 1, 1, 'done', 'machine:claude', ?, ?, ?, 'pending')`, run, Date.now() - 1, Date.now(), reply)
    const admission = vi.spyOn(b, "admitted").mockImplementation(async () => ({ ok: true, config: b.config(), machine: route }))
    const finish = vi.spyOn(b, "finish").mockImplementation(async () => { f.finish() })
    const announce = vi.spyOn(b, "announce").mockImplementation(() => undefined)
    try { await check(b, run, f) } finally { object.doEnv = previous; admission.mockRestore(); finish.mockRestore(); announce.mockRestore() }
  })
}

const drainReply = async (b: ChiefBrainDO, run: string) => {
  // Explicitly deliver a bounded sequence of post jobs; no clock wait or background drain.
  for (let jobs = 0; jobs < 20; jobs++) {
    const next = await b.post(run)
    if (next === null) return
    expect(next).toBeGreaterThan(0)
  }
  throw new Error("reply did not finish within the bounded chunk/retry jobs")
}

const longReply = "🧪漢字e\u0301\n".repeat(18_000) + "\n[Open the built page](https://hello.example.test/final-tail-url)"
const assertComplete = (b: ChiefBrainDO, run: string, f: Fixture) => {
  expect(f.messages.length).toBeGreaterThan(1)
  expect(f.messages.map((m) => m.text).join("")).toBe(longReply)
  expect(f.messages.at(-1)?.text).toContain("https://hello.example.test/final-tail-url")
  const work = f.messages.flatMap((m) => m.parts.filter((p) => p.type === "work"))
  expect(work).toHaveLength(1)
  expect(f.messages.slice(0, -1).every((m) => m.parts.every((p) => p.type === "text"))).toBe(true)
  expect(f.messages.at(-1)?.parts.some((p) => p.type === "work")).toBe(true)
  expect(b.sql.exec<{ post: string }>(`SELECT post FROM cb_turn WHERE id = ?`, run).one().post).toBe("posted")
  expect(f.finish).toHaveBeenCalledOnce()
}

describe("complete machine replies through message.send", () => {
  it("posts every Unicode byte and the final URL within the actual message size limit", async () => {
    expect(new TextEncoder().encode(longReply).length).toBeGreaterThan(MAX_TEXT_BYTES)
    await withReply("unicode", longReply, async (b, run, f) => {
      await drainReply(b, run)
      assertComplete(b, run, f)
    })
  })

  it("replays an ambiguously committed chunk with its original key and no duplicated text", async () => {
    await withReply("ambiguous", longReply, async (b, run, f) => {
      f.loseAt = 2
      expect(await b.post(run)).not.toBeNull()
      const offset = () => b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, `machine-reply-offset:${run}`).toArray()[0]?.value
      const firstOffset = offset()
      expect(Number(firstOffset)).toBeGreaterThan(0)
      expect(await b.post(run)).not.toBeNull()
      expect(offset()).toBe(firstOffset)
      expect(f.messages).toHaveLength(2)
      const unknown = f.attempts.at(-1)!
      await b.post(run)
      expect(f.attempts.at(-1)?.key).toBe(unknown.key)
      expect(f.attempts.at(-1)?.text).toBe(unknown.text)
      expect(f.messages).toHaveLength(2)
      expect(Number(offset())).toBeGreaterThan(Number(firstOffset))
      await drainReply(b, run)
      assertComplete(b, run, f)
    })
  })

  it("uses a fresh key only for a rate-refused chunk, retaining all prior chunks", async () => {
    await withReply("rate", longReply, async (b, run, f) => {
      f.refuseAt = 2
      expect(await b.post(run)).not.toBeNull()
      const first = f.messages[0]!
      expect(await b.post(run)).not.toBeNull()
      expect(f.messages).toHaveLength(1)
      const refused = f.attempts.at(-1)!
      await b.post(run)
      expect(f.attempts.at(-1)?.key).not.toBe(refused.key)
      expect(f.attempts.at(-1)?.text).toBe(refused.text)
      expect(f.messages[0]).toEqual(first)
      expect(f.messages).toHaveLength(2)
      await drainReply(b, run)
      assertComplete(b, run, f)
    })
  })
})
