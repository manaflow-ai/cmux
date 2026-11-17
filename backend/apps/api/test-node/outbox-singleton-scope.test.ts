import { DatabaseSync } from "node:sqlite"
import { describe, expect, it, vi } from "vitest"
import { OwnerEngine, type Domain, type SqlStore } from "@cmux/ownership"
import { drainOutboxChannels } from "../src/owner-outbox.ts"
import { TEAM_MEMBER_LEFT_SOCKETS } from "../src/domains/team-members.ts"

// The Chief brain warm (owner-outbox.ts, MuxDO wakes only) reaches the Workers runtime; no send here uses it.
vi.mock("../src/mux-wake-delivery.ts", () => ({ warmBrain: async () => {} }))

/**
 * Only a Cloud approval answer goes to CloudDO alone (#40370: CloudDO runs the approved create inside the send). Every
 * other item on a CloudDO channel keeps the batch: TeamDO's team.member_left.sockets notices of a bulk member removal
 * went out one per alarm after #40370, so 100 removals took 100 alarm cycles to close the members' sockets.
 */
const sqliteStore = (db: DatabaseSync): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => db.prepare(q).all(...(params as Array<never>)) as Array<T>,
  transaction: <T>(fn: () => T): T => {
    db.exec("BEGIN")
    try {
      const r = fn()
      db.exec("COMMIT")
      return r
    } catch (e) {
      db.exec("ROLLBACK")
      throw e
    }
  },
})

/** Each op queues one item of `kind` to the team's CloudDO, as TeamDO (team-members.ts) and FeedDO (feed-approvals.ts) do. */
const items: Domain<Record<string, never>> = {
  initial: () => ({}),
  reduce: (state, _op, params) => {
    const { kind, n } = params as { kind: string; n: number }
    return { ok: true, state, value: null, outbox: [{ kind, entity: `${kind}:${n}`, payload: { team: "team_s", user: `user_${n}`, request: `apr_${n}` }, target: { class: "CloudDO", name: "team_s" } }] }
  },
}

const drainOnce = async (kinds: ReadonlyArray<string>) => {
  const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), items, { stream: "team:team_s", now: () => Date.now() })
  kinds.forEach((kind, n) => engine.submit({ identity: "session:user_s", kind: "session", user: "user_s" }, { t: "op", op: "x", params: { kind, n }, idempotency_key: `k${n}`, origin: "user" }, () => {}))
  const sends: Array<Array<string>> = []
  const ns = { idFromName: (x: string) => x, get: () => ({ systemDeliver: async (_e: string, _s: string, batch: ReadonlyArray<{ id: number; op: string }>) => (sends.push(batch.map((i) => i.op)), { done: batch.map((i) => i.id) }) }) } as unknown as DurableObjectNamespace
  await drainOutboxChannels(engine, {} as never, () => ns, undefined, undefined, undefined, Infinity)
  return { sends, queued: engine.outboxPending(1_000).length }
}

describe("only a Cloud approval answer is sent alone on a CloudDO channel", () => {
  it("100 team.member_left.sockets notices go out in one drain", async () => {
    const { sends, queued } = await drainOnce(Array.from({ length: 100 }, () => TEAM_MEMBER_LEFT_SOCKETS))
    expect(sends.map((s) => s.length)).toEqual([100])
    expect(queued).toBe(0)
  })

  it("a Cloud approval answer still goes alone, and never in a batch with other items", async () => {
    const answer = "integration.approval.answered"
    expect((await drainOnce([answer, TEAM_MEMBER_LEFT_SOCKETS, answer])).sends).toEqual([[answer]])
    expect((await drainOnce([TEAM_MEMBER_LEFT_SOCKETS, TEAM_MEMBER_LEFT_SOCKETS, answer, TEAM_MEMBER_LEFT_SOCKETS])).sends).toEqual([[TEAM_MEMBER_LEFT_SOCKETS, TEAM_MEMBER_LEFT_SOCKETS]])
  })
})
