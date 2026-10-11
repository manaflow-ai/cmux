import type { Origin, Principal } from "@cmux/ownership"
import { feedDomain } from "../src/domains/feed.ts"
import { agentA, agentB, approvePrompt, choicePrompt, daemon, mac, phone, run, system } from "./feed-harness.ts"

export interface VectorStep {
  readonly principal: Principal
  readonly origin: Origin
  readonly now: number
  readonly tx: string
  readonly op: string
  readonly params: unknown
  readonly expect: { readonly ok: boolean; readonly code?: string; readonly changed?: boolean; readonly value?: unknown }
}
export interface Vector {
  readonly name: string
  readonly steps: ReadonlyArray<VectorStep>
  readonly final_state: unknown
}

/** principal, op, params, origin (default cli), and an optional jump of the clock to this time. */
type Input = [Principal, string, unknown, Origin?, number?]

const req = (kind: string, prompt: unknown, extra: Record<string, unknown> = {}) => ({ type: "request", kind, title: kind, prompt, ...extra })
const ntc = (title: string, extra: Record<string, unknown> = {}) => ({ type: "notice", kind: "notice", title, ...extra })

/** Hand-written scenarios; ids are deterministic from the tx, so later steps can name them. */
const scenarios = (id: (step: number) => string): Record<string, ReadonlyArray<Input>> => ({
  lifecycle: [
    [agentA, "feed.post", req("approve", approvePrompt, { dedupe_key: "claude-code:s1:h1" })],
    [agentA, "feed.post", req("approve", approvePrompt, { dedupe_key: "claude-code:s1:h1" })],
    [agentA, "feed.answer", { item: id(0), answer: { decision: "allow" } }, "user"],
    [mac, "feed.answer", { item: id(0), answer: { decision: "allow" } }, "cli"],
    [phone, "feed.answer", { item: id(0), answer: { decision: "allow", scope: "session" }, device: "iPhone" }, "user"],
    [mac, "feed.answer", { item: id(0), answer: { decision: "deny" } }, "user"],
    [agentA, "feed.post", req("approve", approvePrompt, { dedupe_key: "claude-code:s1:h1" })]
  ],
  dedupe_and_triage: [
    [agentA, "feed.post", ntc("CI failed", { dedupe_key: "ci" })],
    [mac, "feed.read", { items: [id(0)] }, "user"],
    [agentA, "feed.post", ntc("CI failed again", { dedupe_key: "ci" })],
    [agentB, "feed.post", ntc("CI failed", { dedupe_key: "ci" })],
    [mac, "feed.archive", { items: [id(0)] }, "user"],
    [agentA, "feed.post", ntc("CI failed a third time", { dedupe_key: "ci" })],
    [mac, "feed.unarchive", { items: [id(0)] }, "user"],
    [mac, "feed.snooze", { items: [id(3)], until: 2_000_000 }, "user"],
    [mac, "feed.read", { all: true }, "user"]
  ],
  kinds: [
    [agentA, "feed.post", req("choice", choicePrompt)],
    [mac, "feed.answer", { item: id(0), answer: { answers: { db: { selected: ["pg", "sqlite"] }, feat: { selected: ["auth"] } } } }, "user"],
    [mac, "feed.answer", { item: id(0), answer: { answers: { db: { selected: [], other: "DuckDB" }, feat: { selected: ["auth", "sync"] } } } }, "user"],
    [agentA, "feed.post", req("input", { schema: { type: "object", properties: { email: { type: "string", format: "email" } }, required: ["email"] } })],
    [mac, "feed.answer", { item: id(3), answer: { email: "nope" } }, "user"],
    [mac, "feed.answer", { item: id(3), answer: { email: "a@b.co" } }, "user"],
    [agentA, "feed.post", { type: "request", kind: "x-acme.deploy", title: "Deploy?", prompt: { env: "prod" }, answer_schema: { type: "object", properties: { go: { type: "boolean" } }, required: ["go"] } }],
    [mac, "feed.answer", { item: id(6), answer: { go: "yes" } }, "user"],
    [mac, "feed.answer", { item: id(6), answer: { go: true } }, "user"],
    [agentA, "feed.post", { type: "notice", kind: "approve", title: "bad" }]
  ],
  cancel_expire_push: [
    [agentA, "feed.post", req("confirm", { statement: "Delete the branch?" }, { expires_in_ms: 10_000 })],
    [agentB, "feed.cancel", { item: id(0) }],
    [agentA, "feed.post", req("question", { question: "Which port?" })],
    [daemon, "feed.cancel", { item: id(2), reason: "answered_elsewhere" }, "script"],
    [agentA, "feed.post", req("handoff", { reason: "stuck on 2FA" })],
    [mac, "feed.cancel", { item: id(4) }, "user"],
    [system, "feed.expire", { at: 1_030_000 }, "script", 1_030_000],
    [system, "feed.push_due", { at: 1_031_000, send: [id(4)], skip: [] }, "script"],
    [mac, "feed.prefs.set", { push_delay: { high: null } }, "user"]
  ]
})

/** Runs every scenario from an empty feed; the clock moves 1 s per step from 1,000,000 (or jumps forward). */
export const buildVectors = (): ReadonlyArray<Vector> => {
  const out: Array<Vector> = []
  const names = Object.keys(scenarios(() => ""))
  for (const name of names) {
    let state = feedDomain.initial()
    const ids: Array<string> = []
    const id = (step: number) => ids[step] ?? "fi_00000000000000000000"
    const steps: Array<VectorStep> = []
    let now = 999_000
    const inputs = scenarios(id)[name]!
    for (let n = 0; n < inputs.length; n++) {
      // Inputs are rebuilt each step so later steps see ids made by earlier ones.
      const [principal, op, params, origin = "cli", jump] = scenarios(id)[name]![n]!
      now = Math.max(now + 1000, jump ?? 0)
      const tx = `${name}-${n}`
      const r = run(state, principal, op, params, now, tx, origin)
      ids.push(r.ok && (r.value as { item?: { id: string } })?.item?.id ? (r.value as { item: { id: string } }).item.id : "")
      if (r.ok && r.changed) state = r.state
      steps.push({ principal, origin, now, tx, op, params, expect: r.ok ? { ok: true, changed: r.changed, value: r.value } : { ok: false, code: r.code } })
    }
    void inputs
    out.push({ name, steps, final_state: state })
  }
  return out
}
