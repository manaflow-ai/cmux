import { describe, expect, it } from "vitest"
import type { ClientMutants } from "../src/client.ts"
import type { EngineMutants } from "../src/engine.ts"
import { emptyStats, runSim, Violation, type SimConfig } from "./harness.ts"

const base: Omit<SimConfig, "seed"> = {
  steps: 80,
  clients: 2,
  tabs: 3,
  panes: 2,
  maxOpsPerClient: 3,
  maxFaults: 2,
  dupProbability: 0.25
}

const SEEDS = Number(process.env.OWNERSHIP_SEEDS ?? 400)

describe("OwnershipConvergence invariants on the real engine and client", () => {
  it(`holds every safety invariant and converges (${SEEDS} seeds)`, () => {
    let committed = 0
    const stats = emptyStats()
    for (let seed = 1; seed <= SEEDS; seed++) {
      try {
        committed += runSim({ ...base, seed }, stats).committed
      } catch (e) {
        if (e instanceof Violation) throw new Error(`seed ${seed}: ${e.message}`)
        throw e
      }
    }
    // The runs must actually commit ops, or the invariants are vacuous.
    expect(committed).toBeGreaterThan(SEEDS)
    // Each protocol path the invariants guard must actually run.
    expect(stats.snapshots).toBeGreaterThan(0)
    expect(stats.heldReplies).toBeGreaterThan(0)
    expect(stats.crashes).toBeGreaterThan(0)
    expect(stats.replays).toBeGreaterThan(0)
  })

  it("holds with three clients and more faults", () => {
    for (let seed = 1; seed <= Math.ceil(SEEDS / 4); seed++) {
      runSim({ ...base, seed, clients: 3, maxFaults: 4, steps: 120, maxOpsPerClient: 4 })
    }
  })
})

/** Each broken variant from formal/README.md must fail its named invariant. */
const mutants: ReadonlyArray<{ name: string; expect: ReadonlyArray<string>; engine?: EngineMutants; client?: ClientMutants }> = [
  { name: "NoLedger", expect: ["NoDoubleApply"], engine: { noLedger: true } },
  { name: "PublishBeforeCommit", expect: ["NoLostAck"], engine: { publishBeforeCommit: true } },
  { name: "TrustClaimedOwner", expect: ["RecordSingleWriter"], engine: { trustClaimedIdentity: true } },
  { name: "NoGapCheck", expect: ["MirrorIsPrefix"], client: { noGapCheck: true } },
  { name: "DropAtNextDelta", expect: ["PendingVisible"], client: { dropAtNextDelta: true } },
  { name: "SettleBeforeMirror", expect: ["NoFlicker"], client: { settleBeforeMirror: true } },
  { name: "NoResendOnReconnect", expect: ["Convergence"], client: { noResendOnReconnect: true } }
]

describe("mutants are caught", () => {
  for (const m of mutants) {
    it(`${m.name} fails ${m.expect.join(" or ")}`, () => {
      const seen = new Map<string, number>()
      for (let seed = 1; seed <= 3000; seed++) {
        try {
          runSim({ ...base, seed, ...(m.engine ? { engineMutants: m.engine } : {}), ...(m.client ? { clientMutants: m.client } : {}) })
        } catch (e) {
          if (!(e instanceof Violation)) throw e
          seen.set(e.invariant, (seen.get(e.invariant) ?? 0) + 1)
          if (m.expect.includes(e.invariant)) return
        }
      }
      throw new Error(`${m.name} was not caught by ${m.expect.join("/")}; violations seen: ${JSON.stringify(Object.fromEntries(seen))}`)
    })
  }
})
