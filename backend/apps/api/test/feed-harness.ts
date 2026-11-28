import { idFactory, type Origin, type Principal } from "@cmux/ownership"
import { feedDomain, type FeedState } from "../src/domains/feed.ts"

/** Principals the feed tests use (feed.md 3.2). */
export const U = "user_aaaaaaaaaaaaaaaaaaaa"
export const mac: Principal = { identity: "inst_mac00000000000000000", kind: "install", user: U, install: "inst_mac00000000000000000", install_kind: "mac", grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }
export const phone: Principal = { identity: "inst_ios00000000000000000", kind: "install", user: U, install: "inst_ios00000000000000000", install_kind: "ios", grant_classes: ["read", "mutate-own", "mutate-shared", "execute"] }
export const session: Principal = { identity: `session:${U}`, kind: "session", user: U }
/** The daemon posting for one agent (its launch credential, until tokens carry `act`). */
export const agentA: Principal = { identity: "inst_dmn00000000000000000", kind: "install", user: U, install: "inst_dmn00000000000000000", install_kind: "daemon", agent: "agent_a", grant_classes: ["read", "mutate-own", "execute"] }
export const agentB: Principal = { ...agentA, agent: "agent_b" }
export const daemon: Principal = { identity: "inst_dmn00000000000000000", kind: "install", user: U, install: "inst_dmn00000000000000000", install_kind: "daemon", grant_classes: ["read", "mutate-own", "execute"] }
/** A CLI or VM token of the same user: posts, never answers. */
export const vm: Principal = { identity: "inst_vm000000000000000000", kind: "install", user: U, install: "inst_vm000000000000000000", install_kind: "vm", grant_classes: ["read", "mutate-own", "execute"] }
export const system: Principal = { identity: "system:feed", kind: "system" }
export const stranger: Principal = { identity: "inst_zzz00000000000000000", kind: "install", user: "user_bbbbbbbbbbbbbbbbbbbb", install: "inst_zzz00000000000000000", install_kind: "mac", grant_classes: ["read", "mutate-own"] }

export type Step = { ok: true; state: FeedState; value: any; changed: boolean } | { ok: false; code: string; message: string; details?: any; retryable?: boolean }

/** One op the way the engine runs it: authorize, then the pure reducer with a deterministic tx. */
export const run = (state: FeedState, p: Principal, op: string, params: unknown, now: number, tx: string, origin: Origin = "cli"): Step => {
  const denied = feedDomain.authorize!(state, op, params, p)
  if (denied) return { ok: false, code: denied.code, message: denied.message }
  const r = feedDomain.reduce(state, op, params, { principal: p, origin, now, tx, newId: idFactory(tx) })
  if (!r.ok) return { ok: false, code: r.code, message: r.message, ...(r.details === undefined ? {} : { details: r.details }), ...(r.retryable ? { retryable: true } : {}) }
  return { ok: true, state: r.state, value: r.value, changed: r.changed ?? true }
}

/** A tiny driver that keeps state and numbers transactions. */
export const driver = (start = 1_000_000) => {
  let state = feedDomain.initial()
  let n = 0
  let now = start
  const api = {
    get state() {
      return state
    },
    get now() {
      return now
    },
    advance(ms: number) {
      now += ms
    },
    try(p: Principal, op: string, params: unknown, origin: Origin = "cli"): Step {
      const r = run(state, p, op, params, now, `tx${++n}`, origin)
      if (r.ok) state = r.state
      return r
    },
    do(p: Principal, op: string, params: unknown, origin: Origin = "cli"): any {
      const r = api.try(p, op, params, origin)
      if (!r.ok) throw Object.assign(new Error(`${op}: ${r.code} ${r.message}`), { code: r.code })
      return r.value
    }
  }
  return api
}

export const approvePrompt = { action: { type: "command", summary: "Run the build", command: "npm run build", cwd: "/repo" }, scopes: ["once", "session"] }
export const choicePrompt = {
  questions: [
    { id: "db", question: "Which database?", options: [{ id: "pg", label: "Postgres" }, { id: "sqlite", label: "SQLite" }], multi: false, allow_other: true },
    { id: "feat", question: "Which features?", options: [{ id: "auth", label: "Auth" }, { id: "push", label: "Push" }, { id: "sync", label: "Sync" }], multi: true, allow_other: false }
  ]
}
