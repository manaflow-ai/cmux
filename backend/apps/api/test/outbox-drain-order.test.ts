import { env } from "cloudflare:workers"
import { runInDurableObject as runIn } from "cloudflare:test"
import { OwnerEngine, type Domain, type OutboxRow } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import { drainOutboxChannels } from "../src/owner-outbox.ts"

/**
 * Review P1 (drain order): a batch holds a poison upsert and a later delete for the same key. The
 * bad row must be dead before the batch is marked sent, so the sent delete supersedes it and the
 * daily replay can never bring the deleted message back.
 */
const runInDurableObject = runIn as unknown as <T>(stub: unknown, fn: (instance: any) => Promise<T>) => Promise<T>
const testEnv = env as unknown as { FEED_DO: DurableObjectNamespace }

describe("outbox drain order", () => {
  it("a poison upsert followed by a delete of the same message never replays", async () => {
    const stub = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName("drain-order-test"))
    await runInDurableObject(stub, async (instance) => {
      const kinds = ["home.message.upsert", "home.message.delete"]
      const domain: Domain<{ n: number }> = {
        initial: () => ({ n: 0 }),
        reduce: (s) => ({ ok: true, state: { n: s.n + 1 }, value: null, outbox: [{ kind: kinds[s.n]!, entity: "conv_X:5", payload: {} }] })
      }
      const engine = new OwnerEngine(instance.sqlStore, domain, { stream: "test:drain", prefix: "tst_" })
      engine.submit({ identity: "i" }, { t: "op", op: "send", params: {}, idempotency_key: "a" }, () => {})
      engine.submit({ identity: "i" }, { t: "op", op: "delete", params: {}, idempotency_key: "b" }, () => {})
      // PlanetScale refuses the upsert (poison) and applies the delete.
      const project = async (_env: unknown, _stream: string, rows: ReadonlyArray<OutboxRow>) => ({
        sent: rows.filter((r) => r.kind === "home.message.delete").map((r) => r.id),
        dead: rows.filter((r) => r.kind === "home.message.upsert").map((r) => ({ id: r.id, error: "22P02 poison" }))
      })
      await drainOutboxChannels(engine, instance.env, () => undefined, project)
      expect(engine.outbox.pending("")).toEqual([])
      expect(engine.outbox.deadCount()).toBe(0)
      // A day later the replay finds nothing to bring back.
      expect(engine.outbox.replayDead(Date.now() + 25 * 3600_000)).toBe(0)
      expect(engine.outbox.pending("")).toEqual([])
    })
  })
})
