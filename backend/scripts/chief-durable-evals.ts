/**
 * The Chief eval cases (Native/OptChat/optchat-chief/evals/cases) against Cloud Chiefs on the deployed staging API,
 * once per brain: P (`brain_impl: "pi"`, chief-brain/) and D (`"durable"`, chief-durable/), same model, same cases
 * (plans/cmux-next/cloud-chief-durable-DESIGN.md section 9).
 *
 * A case runs when a Cloud Chief can answer it: one user turn, no command stubs, and no check on a host tool
 * (`called`, `posted`, `file_contains`). `not_called` is not graded (a Cloud Chief has none of those tools).
 * Every other check is graded as the Rust runner grades it (chief_eval.rs): reply_matches, reply_not_matches,
 * max_words, no_question, no_raw_ids, silent, and judge (one Claude call through the team subrouter on the
 * tailnet, PASS/FAIL, the same prompt).
 *
 * Per case and brain: a new Chief of the staging e2e account, its brain on with --model, the case history
 * appended to its memory (PUT /memory append; D copies P's memory on its first wake, the path a Chief takes when
 * it moves), then the turn as a message from the owner, then every Chief message until its run ends. The Chief
 * is deleted afterwards.
 *
 *   bun backend/scripts/chief-durable-evals.ts [--env staging|development] [--brains pi,durable] [--model claude-opus-5-5] [--only PREFIX]
 *       [--repeat 1] [--jobs 4] [--report PATH] [--judge gateway|subrouter] [--judge-url http://100.89.225.106:31415]
 *
 * Reads ~/.secrets/cmuxterm-dev.env (Stack project) and ~/.secrets/cmux-next-e2e-cloudchief-staging.env (the
 * throwaway e2e account). Never prints a token. Staging (default) or development only; development runs the free
 * Workers AI model (--model @cf/...), a check of the runner itself.
 */
import { createHash } from "node:crypto"
import { readdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join, resolve } from "node:path"

const arg = (n: string, d: string) => (process.argv.includes(n) ? process.argv[process.argv.indexOf(n) + 1]! : d)
const TARGET = arg("--env", "staging")
if (TARGET !== "staging" && TARGET !== "development") throw new Error(`env ${TARGET} is not allowed: this runner only touches staging or development`)
const API = TARGET === "staging" ? "https://cloud-api-staging.cmux.dev" : "https://cmux-api-development.debussy.workers.dev"
const BRAINS = arg("--brains", "pi,durable").split(",") as Array<"pi" | "durable">
const MODEL = arg("--model", "claude-opus-5-5")
const ONLY = arg("--only", "")
const REPEAT = Number(arg("--repeat", "1"))
const JOBS = Number(arg("--jobs", "4"))
const REPORT = arg("--report", "")
const JUDGE_URL = arg("--judge-url", "http://100.89.225.106:31415")
const JUDGE_MODEL = arg("--judge-model", "claude-sonnet-5")
const TURN_MS = 240_000
/** --second: after the case's turn, one short follow-up ("thanks, anything else?") whose reply time is the warm (second-turn) latency. */
const SECOND = process.argv.includes("--second")
const CASES = resolve(import.meta.dir, "../../Native/OptChat/optchat-chief/evals/cases")

const envFile = (f: string) => Object.fromEntries(readFileSync(join(homedir(), ".secrets", f), "utf8").split("\n").filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).replace(/^export /, ""), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "")])) as Record<string, string>
const stack = envFile("cmuxterm-dev.env")
const account = envFile("cmux-next-e2e-cloudchief-staging.env")
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const runTag = crypto.randomUUID().slice(0, 6)

// ---------------------------------------------------------------- staging API

let token = ""
const signIn = async () => {
  const h = { "content-type": "application/json", "x-stack-project-id": stack.NEXT_PUBLIC_STACK_PROJECT_ID!, "x-stack-publishable-client-key": stack.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY!, "x-stack-access-type": "client" }
  const r = await fetch("https://api.stack-auth.com/api/v1/auth/password/sign-in", { method: "POST", headers: h, body: JSON.stringify({ email: account.CMUX_UITEST_STACK_EMAIL, password: account.CMUX_UITEST_STACK_PASSWORD }) })
  const j = (await r.json()) as { access_token?: string }
  if (!j.access_token) throw new Error(`Stack sign-in: HTTP ${r.status}`)
  token = j.access_token
}
const http = async (method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> => {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(`${API}${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    const raw = await res.text()
    if (res.status === 401 && attempt === 0) {
      await signIn()
      continue
    }
    if ((res.status === 429 || res.status === 503) && attempt < 6) {
      await sleep(1500 * (attempt + 1))
      continue
    }
    let parsed: any = null
    try {
      parsed = JSON.parse(raw)
    } catch {}
    return { status: res.status, body: parsed }
  }
}
const op = (name: string, params: unknown, key: string = crypto.randomUUID()) => http("POST", "/v1/ops", { op: name, params, idempotency_key: key, origin: "user" })
const read = (name: string, params: unknown) => http("POST", "/v1/read", { op: name, params })

// ---------------------------------------------------------------- cases

type Check = { type: string; re?: string; n?: number; rubric?: string }
type Item = { kind?: string; text: string; checks?: Array<Check> }
type Case = { id: string; about?: string; history?: Array<Item>; stubs?: Array<unknown>; turns: Array<Item> }
const HOST_CHECKS = new Set(["called", "posted", "file_contains"])
const runnable = (c: Case): boolean =>
  (c.stubs ?? []).length === 0 && c.turns.length === 1 && (c.turns[0]!.kind ?? "user") === "user" && !(c.turns[0]!.checks ?? []).some((k) => HOST_CHECKS.has(k.type)) && (c.turns[0]!.checks ?? []).some((k) => k.type !== "not_called")
const cases = readdirSync(CASES)
  .filter((f) => f.endsWith(".json") && f.startsWith(ONLY))
  .map((f) => JSON.parse(readFileSync(join(CASES, f), "utf8")) as Case)
  .filter(runnable)

// ---------------------------------------------------------------- grading (chief_eval.rs)

const unlinked = (t: string) => t.replace(/\[[^\]\n]*\]\([^)\s]*\)/g, "LINK")
const rawIds = (text: string): Array<string> => {
  const rest = unlinked(text)
  const out: Array<string> = []
  const pats = [/\b(?:ws|tab|pane|grp|term|conv)_[0-9a-zA-Z]{6,}/g, /(?:cmux|https?|file):\/\/\S+/g, /(?:^|[\s(`])(\/(?:Users|home|tmp|private|var)\/[^\s`)]+)/gm, /\b[0-9a-f]{7,40}\b/g, /(?:^|[\s(])#\d{3,}\b/gm]
  for (const p of pats)
    for (const m of rest.matchAll(p)) {
      const s = m[0].trim()
      if (p.source.includes("0-9a-f]{7") && !(/\d/.test(s) && /[a-z]/i.test(s))) continue
      out.push(s)
    }
  return out
}
/**
 * The judge: the same prompt as chief_eval.rs. Route: the Vercel AI Gateway when ~/.secrets/cmux-ai-gateway.env has
 * AI_GATEWAY_API_KEY (--judge gateway, the default then; model anthropic/<--judge-model>), else the team subrouter
 * (--judge-url, Claude Code shaped). The subrouter's Claude path was down on Oct 28 ("upstream request failed").
 */
const gatewayKey = (() => {
  try {
    return envFile("cmux-ai-gateway.env").AI_GATEWAY_API_KEY
  } catch {
    return undefined
  }
})()
const JUDGE_ROUTE = arg("--judge", gatewayKey ? "gateway" : "subrouter")
const judgeCall = async (prompt: string): Promise<string> => {
  if (JUDGE_ROUTE === "gateway") {
    const res = await fetch("https://ai-gateway.vercel.sh/v1/chat/completions", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${gatewayKey}` }, body: JSON.stringify({ model: `anthropic/${JUDGE_MODEL}`, max_tokens: 400, messages: [{ role: "user", content: prompt }] }) }).catch(() => null)
    const j = res ? ((await res.json().catch(() => null)) as { choices?: Array<{ message?: { content?: string } }> } | null) : null
    return (j?.choices?.[0]?.message?.content ?? "").trim()
  }
  const res = await fetch(`${JUDGE_URL}/v1/messages`, { method: "POST", headers: { "content-type": "application/json", "x-api-key": "unused", "anthropic-version": "2023-06-01", "user-agent": "claude-cli/2.1.300 (external, cli)" }, body: JSON.stringify({ model: JUDGE_MODEL, max_tokens: 400, system: [{ type: "text", text: "You are Claude Code, Anthropic's official CLI for Claude." }], messages: [{ role: "user", content: prompt }] }) }).catch(() => null)
  const j = res ? ((await res.json().catch(() => null)) as { content?: Array<{ text?: string }> } | null) : null
  return (j?.content ?? []).map((b) => b.text ?? "").join("").trim()
}
const judge = async (rubric: string, history: string, message: string, posted: Array<string>): Promise<[boolean, string]> => {
  const prompt = `You grade one turn of an AI assistant ("Chief") that works for one person.\nRubric: ${rubric}\n\n<history>\n${history}\n</history>\n\n<new_message>\n${message}\n</new_message>\n\n<tool_calls>\n\n</tool_calls>\n\n<posted_replies>\n${posted.join("\n---\n")}\n</posted_replies>\n\nAnswer with exactly one line: PASS or FAIL, a colon, and one short reason.`
  for (let i = 0; i < 3; i++) {
    const t = await judgeCall(prompt)
    if (t.startsWith("PASS") || t.startsWith("FAIL")) return [t.startsWith("PASS"), t]
    await sleep(2000)
  }
  return [false, "judge gave no verdict"]
}
const grade = async (c: Case, posted: Array<string>): Promise<Array<{ type: string; pass: boolean; why: string; graded: boolean }>> => {
  const all = posted.join("\n\n")
  const history = (c.history ?? []).map((h) => `${h.kind ?? "user"}: ${h.text}`).join("\n")
  const out = []
  for (const k of c.turns[0]!.checks ?? []) {
    if (k.type === "reply_matches" || k.type === "reply_not_matches") {
      // Rust regex inline flags ((?i), (?s), (?m) at the start) become JS flags.
      const src = k.re ?? ""
      const inline = /^\(\?([ism]+)\)/.exec(src)
      const m = new RegExp(inline ? src.slice(inline[0].length) : src, `u${inline ? inline[1] : ""}`).exec(all)
      out.push(k.type === "reply_matches" ? { type: k.type, pass: !!m, why: m ? "" : `no match for ${k.re}`, graded: true } : { type: k.type, pass: !m, why: m ? `matched ${JSON.stringify(m[0])}` : "", graded: true })
    } else if (k.type === "max_words") {
      const n = all.split(/\s+/).filter(Boolean).length
      out.push({ type: k.type, pass: n <= (k.n ?? 80), why: `${n} words`, graded: true })
    } else if (k.type === "no_question") {
      const q = all.split("\n").filter((l) => l.trimEnd().endsWith("?")).length
      out.push({ type: k.type, pass: q === 0, why: `${q} question lines`, graded: true })
    } else if (k.type === "no_raw_ids") {
      const raw = rawIds(all)
      out.push({ type: k.type, pass: raw.length === 0, why: raw.length ? `raw: ${raw.slice(0, 3).join(", ")}` : "", graded: true })
    } else if (k.type === "silent") out.push({ type: k.type, pass: posted.length === 0, why: posted.length ? "posted something" : "", graded: true })
    else if (k.type === "judge") {
      const [pass, why] = await judge(k.rubric ?? "", history, c.turns[0]!.text, posted)
      out.push({ type: k.type, pass, why, graded: true })
    } else out.push({ type: k.type, pass: true, why: "not graded on a Cloud Chief", graded: false })
  }
  return out
}

// ---------------------------------------------------------------- one case on one brain

const messageKey = (kind: string, date: string, text: string) => createHash("sha256").update(`${kind}\0${Date.parse(date)}\0${text}`).digest("hex")
type Result = { case: string; brain: string; rep: number; pass: boolean; second_ms?: number; checks: Array<{ type: string; pass: boolean; why: string; graded: boolean }>; posted: Array<string>; reply_ms?: number; run?: { id: string; status: string; harness?: string; model?: string; cost_usd?: number; first_token_ms?: number }; error?: string }

const runCase = async (c: Case, brain: "pi" | "durable", rep: number): Promise<Result> => {
  const base: Result = { case: c.id, brain, rep, pass: false, checks: [], posted: [] }
  const made = await op("chief.create", { display_name: `Eval ${brain} ${runTag}` }, `eval-${runTag}-${c.id}-${brain}-${rep}`)
  const chief = made.body?.value as { id: string; main_conversation: string; rev?: number } | undefined
  if (!chief) return { ...base, error: `chief.create: ${JSON.stringify(made.body?.error ?? made.status)}` }
  try {
    const conv = chief.main_conversation
    for (let i = 0; i < 40 && (await read("conversation.history", { conversation: conv, limit: 1 })).status !== 200; i++) await sleep(500)
    const on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, { enabled: true, model: MODEL })
    if (on.status !== 200) return { ...base, error: `brain on: ${on.status} ${JSON.stringify(on.body?.error)}` }
    const history = c.history ?? []
    if (history.length > 0) {
      const t0 = Date.now() - (history.length + 1) * 60_000
      const items = history.map((h, i) => {
        const kind = h.kind === "talk" ? "talk" : h.kind === "note" ? "note" : "user"
        const date = new Date(t0 + i * 60_000).toISOString()
        return { key: messageKey(kind, date, h.text), kind, text: h.text, date, source: "chief-evals" }
      })
      const put = await http("PUT", `/v1/chiefs/${chief.id}/memory?conversation=${conv}`, { mode: "append", batch: `eval-${runTag}`, items })
      if (put.status !== 200) return { ...base, error: `memory append: ${put.status} ${JSON.stringify(put.body?.error)}` }
    }
    if (brain === "durable") {
      const set = await http("PUT", `/v1/chiefs/${chief.id}/brain-impl`, { impl: "durable" })
      if (set.status !== 200) return { ...base, error: `brain-impl durable: ${set.status} ${JSON.stringify(set.body?.error)}` }
    }
    // The message's client_msg_id must equal the op's idempotency key (home-core conversation/apply.ts).
    const msgKey = `eval-${runTag}-${brain}-${rep}-${c.id}`.slice(0, 120)
    const sent = await op("message.send", { conversation: conv, client_msg_id: msgKey, parts: [{ type: "text", text: c.turns[0]!.text }] }, msgKey)
    if (sent.status !== 200 || sent.body?.ok === false) return { ...base, error: `message.send: ${sent.status} ${JSON.stringify(sent.body?.error ?? "")}` }
    const start = Date.now()
    const mine = async () => ((await read("conversation.history", { conversation: conv, limit: 50 })).body?.value?.messages ?? []).filter((m: any) => m.author === chief.id) as Array<any>
    const runs = async () => ((await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conv}`)).body?.value?.runs ?? []) as Array<any>
    let firstReply: number | undefined
    let ended: any
    while (Date.now() - start < TURN_MS) {
      const [m, r] = await Promise.all([mine(), runs()])
      if (m.length > 0 && firstReply === undefined) firstReply = Date.now() - start
      ended = r.find((x) => x.status !== "running")
      if (ended && (m.length > 0 || ended.reply?.state === "no_reply" || ended.status === "failed")) break
      await sleep(1000)
    }
    await sleep(1500)
    // Graded: the replies to the case's own turn, read before any follow-up.
    const posted = (await mine()).map((m) => (m.parts ?? []).filter((p: any) => p.type === "text").map((p: any) => p.text).join(""))
    let second_ms: number | undefined
    if (SECOND) {
      const before = (await mine()).length
      const k2 = `${msgKey}-2`.slice(0, 120)
      await op("message.send", { conversation: conv, client_msg_id: k2, parts: [{ type: "text", text: "thanks. one line: what is the next step?" }] }, k2)
      const t2 = Date.now()
      while (Date.now() - t2 < TURN_MS && (await mine()).length <= before) await sleep(500)
      if ((await mine()).length > before) second_ms = Date.now() - t2
    }
    const checks = await grade(c, posted)
    const runInfo = ended ? { id: ended.id, status: ended.status, harness: ended.harness, model: ended.model, cost_usd: ended.cost_usd, first_token_ms: ended.timing?.first_token_at && ended.started_at ? ended.timing.first_token_at - ended.started_at : undefined } : undefined
    const error = ended ? (ended.status === "failed" ? `run failed: ${JSON.stringify(ended.error ?? ended.reason ?? "")}` : undefined) : "no run ended in time"
    return { ...base, pass: !error && checks.every((k) => k.pass), checks, posted, ...(firstReply === undefined ? {} : { reply_ms: firstReply }), ...(second_ms === undefined ? {} : { second_ms }), ...(runInfo ? { run: runInfo } : {}), ...(error ? { error } : {}) }
  } finally {
    await op("chief.delete", { chief: chief.id, expected_rev: chief.rev ?? 1 }).catch(() => undefined)
  }
}

// ---------------------------------------------------------------- main

await signIn()
console.log(`${cases.length} cases a Cloud Chief can answer; brains ${BRAINS.join(", ")}; model ${MODEL}; judge ${JUDGE_ROUTE} ${JUDGE_MODEL}; repeat ${REPEAT}; run ${runTag}`)
const jobs = cases.flatMap((c) => BRAINS.flatMap((b) => Array.from({ length: REPEAT }, (_, rep) => ({ c, b, rep }))))
const results: Array<Result> = []
let next = 0
await Promise.all(
  Array.from({ length: JOBS }, async () => {
    while (next < jobs.length) {
      const j = jobs[next++]!
      const r = await runCase(j.c, j.b, j.rep).catch((e: unknown): Result => ({ case: j.c.id, brain: j.b, rep: j.rep, pass: false, checks: [], posted: [], error: String(e) }))
      results.push(r)
      const failed = r.checks.filter((k) => !k.pass).map((k) => `${k.type}: ${k.why}`)
      console.log(`${r.pass ? "PASS" : "FAIL"}  ${r.brain.padEnd(7)} ${r.case}${r.reply_ms === undefined ? "" : ` (${(r.reply_ms / 1000).toFixed(1)} s)`}${r.error ? ` -- ${r.error}` : ""}${failed.length ? ` -- ${failed.join("; ").slice(0, 300)}` : ""}`)
    }
  })
)
const pct = (a: number, b: number) => (b === 0 ? "n/a" : `${((100 * a) / b).toFixed(0)}%`)
const median = (xs: Array<number>) => (xs.length ? [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]! : NaN)
const summary = BRAINS.map((b) => {
  const rs = results.filter((r) => r.brain === b)
  const checks = rs.flatMap((r) => r.checks.filter((k) => k.graded))
  const cost = rs.reduce((s, r) => s + (r.run?.cost_usd ?? 0), 0)
  return { brain: b, cases: rs.length, passed: rs.filter((r) => r.pass).length, errors: rs.filter((r) => r.error).length, checks: checks.length, checks_passed: checks.filter((k) => k.pass).length, reply_p50_s: median(rs.flatMap((r) => (r.reply_ms === undefined ? [] : [r.reply_ms / 1000]))), second_p50_s: median(rs.flatMap((r) => (r.second_ms === undefined ? [] : [r.second_ms / 1000]))), cost_usd: Number(cost.toFixed(4)) }
})
for (const s of summary) console.log(`${s.brain}: ${s.passed}/${s.cases} cases (${pct(s.passed, s.cases)}), ${s.checks_passed}/${s.checks} checks (${pct(s.checks_passed, s.checks)}), ${s.errors} errors, reply p50 ${s.reply_p50_s.toFixed(1)} s${Number.isNaN(s.second_p50_s) ? "" : `, second reply p50 ${s.second_p50_s.toFixed(1)} s`}, model cost $${s.cost_usd}`)
if (REPORT) writeFileSync(REPORT, `${JSON.stringify({ run: runTag, api: API, model: MODEL, judge: `${JUDGE_ROUTE}:${JUDGE_MODEL}`, at: new Date().toISOString(), summary, results }, null, 2)}\n`)
