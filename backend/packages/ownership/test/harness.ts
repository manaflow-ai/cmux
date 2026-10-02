/**
 * A randomized model of OwnershipConvergence.tla running the REAL OwnerEngine
 * (node:sqlite) and the REAL ProjectionClient. Channels reorder, duplicate and
 * lose messages on disconnect; the owner can crash inside its commit
 * transaction and restart from durable storage. Every step checks the TLA+
 * safety invariants; the end heals the system and checks Convergence.
 */
import { DatabaseSync } from "node:sqlite"
import { ProjectionClient, type ClientMutants, type ClientOut } from "../src/client.ts"
import { canonicalJson, OwnerEngine, type EngineMutants, type SqlStore } from "../src/engine.ts"
import type { Domain, OwnerFrame, Principal } from "../src/types.ts"

// ---------------------------------------------------------------- the model domain

export interface TabState {
  readonly layout: Record<string, ReadonlyArray<string>>
  readonly records: Record<string, string | null>
}
export type TabParams =
  | { readonly tab: string; readonly pane: string }
  | { readonly tab: string }
  | { readonly target: string; readonly claimed_identity?: string }

export const tabDomain = (tabs: ReadonlyArray<string>, panes: ReadonlyArray<string>, clients: ReadonlyArray<string>): Domain<TabState, TabParams> => ({
  initial: () => ({
    layout: Object.fromEntries(panes.map((p, i) => [p, i === 0 ? [...tabs] : []])),
    records: Object.fromEntries(clients.map((c) => [c, null]))
  }),
  reduce: (st, op, params, ctx) => {
    const live = new Set(Object.values(st.layout).flat())
    if (op === "write") {
      const { target } = params as { target: string }
      // Single writer: a client-owned record is written only by the connection's identity.
      if (target !== ctx.principal.identity) return { ok: false, code: "forbidden", message: "not the record owner" }
      // The record stores the authenticated connection (install), as OwnershipConvergence.tla stores `from`.
      const writer = ctx.principal.install ?? ctx.principal.identity
      return { ok: true, state: { ...st, records: { ...st.records, [target]: writer } }, value: null }
    }
    const { tab } = params as { tab: string }
    if (!live.has(tab)) return { ok: false, code: "selector.not_found", message: "tab is gone" }
    const stripped = Object.fromEntries(Object.entries(st.layout).map(([p, ts]) => [p, ts.filter((t) => t !== tab)]))
    if (op === "close") return { ok: true, state: { ...st, layout: stripped }, value: null }
    if (op === "move") {
      const { pane } = params as { pane: string }
      if (!(pane in stripped)) return { ok: false, code: "selector.not_found", message: "pane is gone" }
      return { ok: true, state: { ...st, layout: { ...stripped, [pane]: [...stripped[pane]!, tab] } }, value: null }
    }
    return { ok: false, code: "validation.invalid", message: `unknown op ${op}` }
  }
})

// ---------------------------------------------------------------- storage

export const sqliteStore = (db: DatabaseSync): SqlStore => ({
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
  }
})

// ---------------------------------------------------------------- PRNG

export const rng = (seed: number) => {
  let s = seed >>> 0 || 1
  const next = () => {
    s ^= s << 13
    s ^= s >>> 17
    s ^= s << 5
    return (s >>> 0) / 0x100000000
  }
  return {
    next,
    int: (n: number) => Math.floor(next() * n),
    pick: <T>(xs: ReadonlyArray<T>): T => xs[Math.floor(next() * xs.length)]!,
    chance: (p: number) => next() < p
  }
}

// ---------------------------------------------------------------- simulation

export interface SimConfig {
  readonly seed: number
  readonly steps: number
  readonly clients: number
  readonly tabs: number
  readonly panes: number
  readonly maxOpsPerClient: number
  readonly maxFaults: number
  readonly dupProbability: number
  readonly engineMutants?: EngineMutants
  readonly clientMutants?: ClientMutants
}

export class Violation extends Error {
  constructor(
    readonly invariant: string,
    detail: string
  ) {
    super(`${invariant}: ${detail}`)
  }
}

type ToOwner = { readonly from: number; readonly msg: ClientOut }

export interface SimStats {
  snapshots: number
  heldReplies: number
  crashes: number
  replays: number
}
export const emptyStats = (): SimStats => ({ snapshots: 0, heldReplies: 0, crashes: 0, replays: 0 })

export const runSim = (cfg: SimConfig, stats: SimStats = emptyStats()): { steps: number; committed: number } => {
  const r = rng(cfg.seed)
  const tabs = Array.from({ length: cfg.tabs }, (_, i) => `t${i}`)
  const panes = Array.from({ length: cfg.panes }, (_, i) => `p${i}`)
  const ids = Array.from({ length: cfg.clients }, (_, i) => `c${i}`)
  const domain = tabDomain(tabs, panes, ids)
  const db = new DatabaseSync(":memory:")
  const sql = sqliteStore(db)
  let crashArmed = false
  let ownerDead = false
  let faults = 0
  const toOwner: Array<ToOwner> = []
  const toClient: Array<Array<OwnerFrame>> = ids.map(() => [])
  const rejectedSeen = new Set<string>() // `${identity}|${key}` rejects the engine emitted (for the noLedger mutant)
  const issued: Array<Array<string>> = ids.map(() => [])

  const makeEngine = () =>
    new OwnerEngine(sql, domain, {
      stream: "doc:test",
      now: () => 0,
      ...(cfg.engineMutants ? { mutants: cfg.engineMutants } : {}),
      beforeCommit: () => {
        if (crashArmed) {
          crashArmed = false
          throw new Error("crash before commit")
        }
      }
    })
  let engine = makeEngine()

  const clients = ids.map(
    (id, i) =>
      new ProjectionClient<TabState, TabParams>(domain, { identity: id, install: id } satisfies Principal, (msg) => toOwner.push({ from: i, msg }), cfg.clientMutants ?? {}, id)
  )

  const deliver = (target: "all" | string, frame: OwnerFrame) => {
    if ((frame.t === "result" || frame.t === "reject") && frame.replayed) stats.replays++
    if (frame.t === "request-settled" && !frame.ok && target !== "all") rejectedSeen.add(`${target}|${frame.idempotency_key}`)
    ids.forEach((id, i) => {
      if ((target === "all" || target === id) && clients[i]!.connected) toClient[i]!.push(frame)
    })
  }

  // ---- durable views for the invariants
  const events = () => engine.eventsAfter(0, 1_000_000)
  const ledger = () => sql.exec<{ identity: string; idempotency_key: string; ok: number }>(`SELECT identity, idempotency_key, ok FROM own_ledger`)
  const replay = (k: number) => {
    let st = domain.initial()
    for (const e of events().slice(0, k)) {
      const res = domain.reduce(st, e.op, e.params as TabParams, { principal: e.actor, now: e.at, tx: e.tx, newId: () => "x" })
      if (!res.ok) throw new Violation("Replay", `committed op rejected on replay at ${e.seq}`)
      st = res.state
    }
    return st
  }
  const durableState = () => replay(Number.MAX_SAFE_INTEGER)
  const appliedSeq = (identity: string, key: string): number | undefined => {
    const tx = engine.txTag(identity, key)
    return events().find((e) => e.tx === tx)?.seq
  }
  const noDup = (layout: TabState["layout"]) => {
    const all = Object.values(layout).flat()
    return new Set(all).size === all.length
  }

  const check = () => {
    const evs = events()
    // NoDoubleApply (principle 5): every committed transaction appears once.
    const txs = evs.map((e) => e.tx)
    if (new Set(txs).size !== txs.length) throw new Violation("NoDoubleApply", "a key was applied twice")
    evs.forEach((e, i) => {
      if (e.seq !== i + 1) throw new Violation("NoDoubleApply", "event sequence has a gap")
    })
    const durable = durableState()
    // Conservation and NoSilentLoss (principles 1, 2 at protocol level).
    if (!noDup(durable.layout)) throw new Violation("Conservation", "owner duplicates a tab")
    const live = new Set(Object.values(durable.layout).flat())
    for (const t of tabs) {
      if (!live.has(t) && !evs.some((e) => e.op === "close" && (e.params as { tab: string }).tab === t)) {
        throw new Violation("NoSilentLoss", `tab ${t} vanished without a close`)
      }
    }
    // RecordSingleWriter: judged by connection identity.
    for (const [rec, writer] of Object.entries(durable.records)) {
      if (writer !== null && writer !== rec) throw new Violation("RecordSingleWriter", `record ${rec} written by ${writer}`)
    }
    const decided = new Set(ledger().map((l) => `${l.identity}|${l.idempotency_key}`))
    clients.forEach((c, i) => {
      const id = ids[i]!
      // TypeOK: no mirror is ahead of the owner.
      if (c.confirmed.seq > evs.length) throw new Violation("TypeOK", "mirror ahead of owner")
      // MirrorIsPrefix (principle 4).
      if (canonicalJson(c.confirmed.state) !== canonicalJson(replay(c.confirmed.seq))) {
        throw new Violation("MirrorIsPrefix", `client ${id} mirror differs from owner prefix ${c.confirmed.seq}`)
      }
      if (!noDup(c.confirmed.state.layout) || !noDup(c.view().layout)) throw new Violation("Conservation", `client ${id} shows a tab twice`)
      for (const key of c.settledOk) {
        const seq = appliedSeq(id, key)
        // NoLostAck (principle 6): an acknowledged op is durable, across restarts.
        if (seq === undefined) throw new Violation("NoLostAck", `client ${id} settled ${key} but it is not durable`)
        // NoFlicker: the intent never leaves before its effect is in the mirror.
        if (c.confirmed.seq < seq) throw new Violation("NoFlicker", `client ${id} settled ${key} before its mirror reached ${seq}`)
      }
      // PendingVisible (principle 6): undecided intents stay in the log.
      for (const key of issued[i]!) {
        const k = `${id}|${key}`
        const isDecided = decided.has(k) || appliedSeq(id, key) !== undefined || rejectedSeen.has(k)
        if (!isDecided && !c.pending.some((p) => p.idempotency_key === key)) {
          throw new Violation("PendingVisible", `client ${id} dropped undecided ${key}`)
        }
      }
    })
  }

  // ---- actions
  const ownerReceive = (keep: boolean) => {
    if (ownerDead || toOwner.length === 0) return
    const idx = r.int(toOwner.length)
    const m = toOwner[idx]!
    if (!keep) toOwner.splice(idx, 1)
    const id = ids[m.from]!
    if (m.msg.t === "snapshot.request") {
      if (clients[m.from]!.connected) toClient[m.from]!.push(engine.snapshot(id, m.msg.pending))
      return
    }
    try {
      engine.submit({ identity: id, install: id }, m.msg.frame, deliver)
    } catch {
      ownerDead = true // crashed inside the commit: the staged op is lost
      stats.crashes++
    }
  }
  const clientReceive = (i: number, keep: boolean) => {
    const ch = toClient[i]!
    if (ch.length === 0 || !clients[i]!.connected) return
    const idx = r.int(ch.length)
    const f = ch[idx]!
    if (!keep) ch.splice(idx, 1)
    if (f.t === "snapshot") stats.snapshots++
    const heldBefore = clients[i]!.held.length
    clients[i]!.receive(f)
    if (clients[i]!.held.length > heldBefore) stats.heldReplies++
    // A correct client never sees its reducer refuse a committed op.
    if (clients[i]!.desyncs > 0) throw new Violation("MirrorIsPrefix", `client ${ids[i]} could not replay a committed op`)
  }
  const restart = () => {
    engine = makeEngine()
    ownerDead = false
    crashArmed = false
    toOwner.length = 0
    toClient.forEach((ch) => (ch.length = 0))
    clients.forEach((c) => c.disconnect())
  }
  const issue = (i: number) => {
    const c = clients[i]!
    if (!c.connected || issued[i]!.length >= cfg.maxOpsPerClient) return
    const kind = r.int(3)
    const params: TabParams =
      kind === 0
        ? { tab: r.pick(tabs), pane: r.pick(panes) }
        : kind === 1
          ? { tab: r.pick(tabs) }
          : // A write may target someone else's record and claim their identity in the body.
            ((t) => ({ target: t, claimed_identity: t }))(r.pick(ids))
    issued[i]!.push(c.issue(kind === 0 ? "move" : kind === 1 ? "close" : "write", params))
  }

  let step = 0
  for (; step < cfg.steps; step++) {
    const i = r.int(cfg.clients)
    const c = clients[i]!
    const roll = r.next()
    if (roll < 0.15) issue(i)
    else if (roll < 0.2 && c.pending.length > 0) c.retry(r.pick(c.pending).idempotency_key)
    else if (roll < 0.24 && c.connected && faults < cfg.maxFaults) {
      faults++
      c.disconnect()
      toClient[i]!.length = 0
      for (let k = toOwner.length - 1; k >= 0; k--) if (toOwner[k]!.from === i) toOwner.splice(k, 1)
    } else if (roll < 0.3 && !c.connected && !ownerDead) c.reconnect()
    else if (roll < 0.33 && faults < cfg.maxFaults && !ownerDead) {
      faults++
      crashArmed = true
    } else if (roll < 0.37 && (ownerDead || (faults < cfg.maxFaults && r.chance(0.3)))) {
      if (!ownerDead) faults++
      restart()
    } else if (roll < 0.65) ownerReceive(r.chance(cfg.dupProbability))
    else clientReceive(i, r.chance(cfg.dupProbability))
    check()
  }

  // ---- heal: fair delivery, no faults, no duplication, until quiescent
  crashArmed = false
  if (ownerDead) restart()
  clients.forEach((c) => {
    if (!c.connected) c.reconnect()
  })
  for (let guard = 0; guard < 100_000; guard++) {
    if (toOwner.length > 0) {
      ownerReceive(false)
    } else {
      const busy = toClient.findIndex((ch) => ch.length > 0)
      if (busy < 0) break
      clientReceive(busy, false)
    }
    check()
  }
  const durable = durableState()
  clients.forEach((c, i) => {
    if (c.pending.length > 0 || c.held.length > 0) throw new Violation("Convergence", `client ${ids[i]} still has ${c.pending.length} intents at quiescence`)
    if (c.confirmed.seq !== engine.currentSeq) throw new Violation("Convergence", `client ${ids[i]} at ${c.confirmed.seq}, owner at ${engine.currentSeq}`)
    if (canonicalJson(c.view()) !== canonicalJson(durable)) throw new Violation("Convergence", `client ${ids[i]} view differs from owner`)
  })
  if (canonicalJson(engine.currentState) !== canonicalJson(durable)) throw new Violation("Convergence", "owner memory differs from durable log")
  db.close()
  return { steps: step, committed: engine.currentSeq }
}
