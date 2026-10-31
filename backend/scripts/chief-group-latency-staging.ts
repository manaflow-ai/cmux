/**
 * Group chat latency against the deployed staging API: how long a Home group with two people and their two
 * Chiefs (model `fake`, no model cost) takes to answer, over many runs, with p50/p95 and a per-stage split.
 *
 *   mention  Ben sends "@Bolt ..."; until Bolt's reply is on Ann's socket.
 *   all      wake_policy "all"; Ben sends a message; until the first and until both Chiefs' replies are on Ann's socket.
 *
 * Stages come from the run's timing marks (brain-runs.ts Run.timing) and the event `at` of the person's
 * message and of the reply, all on the server clock: commit -> mux (MuxDO took the wake) -> wake (brain got it)
 * -> admitted -> settled -> submit -> request -> first token -> ended -> reply committed.
 *
 *   bun backend/scripts/chief-group-latency-staging.ts [--runs 12] [--report PATH] [--keep]
 *
 * Two throwaway Stack accounts (`chief-lat-<run>-<a|b>@example.test`), deleted at the end unless --keep.
 * Reads ~/.secrets/cmuxterm-dev.env; never prints a token or key. Staging only.
 */
import { readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { createHash } from "node:crypto"

const arg = (n: string, d: string) => (process.argv.includes(n) ? process.argv[process.argv.indexOf(n) + 1]! : d)
const API = "https://cloud-api-staging.cmux.dev"
const WS = API.replace(/^https/, "wss")
const RUNS = Number(arg("--runs", "12"))
const reportPath = arg("--report", "")
const keep = process.argv.includes("--keep")
const secrets = Object.fromEntries(readFileSync(join(homedir(), ".secrets", "cmuxterm-dev.env"), "utf8").split("\n").filter((l) => l.includes("=") && !l.startsWith("#")).map((l) => [l.slice(0, l.indexOf("=")).replace(/^export /, ""), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "")])) as Record<string, string>
const projectId = secrets.NEXT_PUBLIC_STACK_PROJECT_ID!
const run = crypto.randomUUID().slice(0, 8)
const STACK = "https://api.stack-auth.com/api/v1"
const clientHeaders = { "content-type": "application/json", "x-stack-project-id": projectId, "x-stack-publishable-client-key": secrets.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY!, "x-stack-access-type": "client" }
const serverHeaders = { "content-type": "application/json", "x-stack-project-id": projectId, "x-stack-secret-server-key": secrets.STACK_SECRET_SERVER_KEY ?? "", "x-stack-access-type": "server" }
const hex20 = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 20)
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

interface Reply { status: number; body: any; raw: string }
const http = async (method: string, path: string, token: string | undefined, body?: unknown, team?: string): Promise<Reply> => {
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(`${API}${path}`, { method, headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...(team ? { "x-cmux-team": team } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
    const raw = await res.text()
    if (res.status === 429 || res.status === 503) { await sleep(1500 * (attempt + 1)); continue }
    let parsed: any = null
    try { parsed = JSON.parse(raw) } catch {}
    return { status: res.status, body: parsed, raw }
  }
  return { status: 429, body: null, raw: "rate limited" }
}
const op = (t: string, name: string, params: unknown, key: string = crypto.randomUUID()) => http("POST", "/v1/ops", t, { op: name, params, idempotency_key: key, origin: "user" })
const read = (t: string, name: string, params: unknown, team?: string) => http("POST", "/v1/read", t, { op: name, params }, team)
const ok = (r: Reply) => r.status === 200 && r.body?.ok !== false && r.body?.error === undefined
const poll = async <T>(f: () => Promise<T | undefined>, ms = 60_000, every = 750): Promise<T | undefined> => {
  const start = Date.now()
  while (Date.now() - start < ms) {
    const v = await f()
    if (v !== undefined) return v
    await sleep(every)
  }
  return undefined
}

interface Person { tag: string; name: string; stackUser: string; session: string; user: string; chief?: { id: string; display_name: string } }
const signUp = async (tag: string, name: string): Promise<Person> => {
  const email = `chief-lat-${run}-${tag}@example.test`
  const up = await fetch(`${STACK}/auth/password/sign-up`, { method: "POST", headers: clientHeaders, body: JSON.stringify({ email, password: `Lat-${crypto.randomUUID()}!` }) })
  if (!up.ok) throw new Error(`Stack sign-up ${tag}: ${up.status}`)
  const j = (await up.json()) as { access_token: string; user_id: string }
  await fetch(`${STACK}/users/${j.user_id}`, { method: "PATCH", headers: serverHeaders, body: JSON.stringify({ display_name: name }) })
  const ensured = await op(j.access_token, "user.ensure", {})
  if (!ok(ensured)) throw new Error(`user.ensure ${tag}: ${ensured.raw.slice(0, 200)}`)
  return { tag, name, stackUser: j.user_id, session: j.access_token, user: ensured.body.value.id }
}

/** Ann's conversation socket; every frame with the time it arrived. */
const socket = async (p: Person, conversation: string) => {
  const ws = new WebSocket(`${WS}/v1/wire/conv/${conversation}`, { headers: { authorization: `Bearer ${p.session}` }, protocols: ["cmux.wire.v1"] } as any)
  const frames: Array<{ at: number; f: any }> = []
  ws.addEventListener("message", (e) => { try { frames.push({ at: Date.now(), f: JSON.parse(String(e.data)) }) } catch {} })
  await new Promise<void>((resolve, reject) => { ws.addEventListener("open", () => resolve()); ws.addEventListener("error", () => reject(new Error(`socket ${p.tag}`))) })
  ws.send(JSON.stringify({ t: "subscribe" }))
  const until = async (pred: (f: any) => boolean, ms = 60_000) => poll(async () => frames.find((x) => pred(x.f)), ms, 10)
  return { ws, frames, until }
}
const textPart = (t: string, runs?: unknown) => ({ type: "text", text: t, ...(runs ? { runs } : {}) })
const send = async (p: Person, conversation: string, part: unknown) => {
  const key = crypto.randomUUID()
  const t0 = Date.now()
  const r = await op(p.session, "message.send", { conversation, client_msg_id: key, parts: [part] }, key)
  return { ok: ok(r), key, id: r.body?.value?.message_id as string | undefined, t0, raw: r.raw }
}
const mention = (c: NonNullable<Person["chief"]>, text: string) => textPart(`@${c.display_name} ${text}`, [{ start: 0, length: c.display_name.length + 1, mention: c.id }])
/** A committed message.send event authored by `chief` after ledger seq `seq` (event seq is the owner ledger's, not the message's). */
const replyBy = (chief: string, seq: number) => (f: any) => f.t === "event" && f.op === "message.send" && f.seq > seq && JSON.stringify(f.actor ?? "").includes(chief)
/** The person's own message.send event, by its client_msg_id. */
const msgEvent = (key: string) => (f: any) => f.t === "event" && f.op === "message.send" && f.params?.client_msg_id === key
/** The ledger event of a send, then the first reply by `chief` after it. */
const replyTo = async (sa: Awaited<ReturnType<typeof socket>>, key: string, chief: string, ms: number) => {
  const msg = await sa.until(msgEvent(key), ms)
  if (!msg) return { msg: undefined, reply: undefined }
  return { msg, reply: await sa.until(replyBy(chief, msg.f.seq), ms) }
}

const pct = (xs: ReadonlyArray<number>, p: number) => {
  if (xs.length === 0) return NaN
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))]!
}
const series: Record<string, Array<number>> = {}
const rows: Array<unknown> = []
const add = (k: string, v: number | undefined) => { if (v !== undefined && Number.isFinite(v)) (series[k] ??= []).push(v) }

const STAGES = ["mux", "wake", "admitted", "settled", "submit", "request", "first_token", "ended"] as const
/** Per-stage deltas of one run: each mark minus the previous one present, from the person's message commit to the reply commit. */
const stages = (prefix: string, msgAt: number, runRow: any, replyAt: number | undefined) => {
  const t = runRow?.timing ?? {}
  const marks: Record<string, number | undefined> = { mux: t.mux_at, wake: t.wake_at, admitted: t.admitted_at, settled: t.settled_at, submit: t.submit_at, request: t.request_at, first_token: t.first_token_at, ended: runRow?.ended_at }
  rows.push({ prefix, msgAt, replyAt, marks: Object.fromEntries(Object.entries(marks).map(([k, v]) => [k, typeof v === "number" ? v - msgAt : null])), post: runRow?.post ?? runRow?.post_tries })
  let prev = msgAt
  for (const s of STAGES) {
    const v = marks[s]
    if (typeof v !== "number") continue
    add(`${prefix}.stage.${s}`, v - prev)
    prev = v
  }
  if (replyAt !== undefined) add(`${prefix}.stage.post`, replyAt - prev)
}
/** The Chief's run that answered the message committed at `msgAt` (the oldest finished run started after it). */
const runFor = async (p: Person, chief: string, conversation: string, msgAt: number) =>
  poll(async () => {
    const r = await http("GET", `/v1/chiefs/${chief}/runs?conversation=${conversation}&limit=5`, p.session)
    const v = r.body?.value
    const runs = (Array.isArray(v) ? v : (v?.runs ?? [])) as Array<any>
    return runs.filter((x) => x.started_at >= msgAt - 50 && x.ended_at !== undefined).sort((a, b) => a.started_at - b.started_at)[0]
  }, 15_000, 500)

const people: Array<Person> = []
let stackTeam: string | undefined
let failures = 0
try {
  const ann = await signUp("a", `Ann ${run}`); people.push(ann)
  const ben = await signUp("b", `Ben ${run}`); people.push(ben)
  for (const p of [ann, ben]) p.chief = (await op(p.session, "chief.create", { display_name: p.tag === "a" ? "Atlas" : "Bolt" }, `chief-lat-${run}-${p.tag}`)).body?.value
  if (!secrets.STACK_SECRET_SERVER_KEY) throw new Error("no STACK_SECRET_SERVER_KEY")
  const team = await fetch(`${STACK}/teams`, { method: "POST", headers: serverHeaders, body: JSON.stringify({ display_name: `chief-lat-${run}`, creator_user_id: ann.stackUser }) })
  stackTeam = ((await team.json()) as { id?: string }).id
  await fetch(`${STACK}/team-memberships/${stackTeam}/${ben.stackUser}`, { method: "POST", headers: serverHeaders, body: "{}" })
  const cmuxTeam = `team_${hex20(`stack-team:${projectId}:${stackTeam}`)}`
  await poll(async () => {
    const users = (((await read(ben.session, "team.members.list", { team: cmuxTeam }, cmuxTeam)).body?.value?.members ?? []) as Array<{ user: string }>).map((m) => m.user)
    return users.includes(ann.user) && users.includes(ben.user) ? true : undefined
  }, 90_000, 2000)
  const created = await op(ann.session, "conversation.create", { kind: "group", title: `Latency ${run}`, participants: [{ id: ann.user, kind: "human", display_name: ann.name }, { id: ben.user, kind: "human", display_name: ben.name }, { id: ann.chief!.id, kind: "agent", agent_class: "mux", display_name: "Atlas" }] })
  const group = created.body?.value?.conversation?.id as string
  if (!group) throw new Error(`group: ${created.raw.slice(0, 200)}`)
  await op(ben.session, "participants.add", { conversation: group, participant: { id: ben.chief!.id, kind: "agent", agent_class: "mux", display_name: "Bolt" } })
  for (const p of [ann, ben]) await http("PUT", `/v1/chiefs/${p.chief!.id}/brain`, p.session, { enabled: true, model: "fake", compactor_model: "fake" })
  const sa = await socket(ann, group)
  // Warm both brains once (a cold start is its own number, not this bench's).
  for (const p of [ben, ann]) {
    const w = await send(p, group, mention(p.chief!, `warm ${run}`))
    await replyTo(sa, w.key, p.chief!.id, 60_000)
    await sleep(3000)
  }

  // ---- mention: one Chief answers.
  for (let i = 0; i < RUNS; i++) {
    const q = await send(ben, group, mention(ben.chief!, `ping ${run}-${i}`))
    const { msg, reply } = await replyTo(sa, q.key, ben.chief!.id, 60_000)
    if (!reply || !msg) { failures++; console.log(`mention ${i}: no reply`); continue }
    add("mention.client_ms", reply.at - q.t0)
    add("mention.server_ms", reply.f.at - msg.f.at)
    stages("mention", msg.f.at, await runFor(ben, ben.chief!.id, group, msg.f.at), reply.f.at)
    console.log(`mention ${i}: client ${reply.at - q.t0} ms, server ${reply.f.at - msg.f.at} ms`)
    await sleep(3000)
  }

  // ---- all: both Chiefs answer one person's message.
  const set = await op(ann.session, "conversation.settings.set", { conversation: group, wake_policy: "all" })
  if (!ok(set)) throw new Error(`settings.set: ${set.raw.slice(0, 200)}`)
  for (let i = 0; i < RUNS; i++) {
    const st = await send(ben, group, textPart(`status ${run}-${i}?`))
    const [ra, rb] = await Promise.all([replyTo(sa, st.key, ann.chief!.id, 150_000), replyTo(sa, st.key, ben.chief!.id, 150_000)])
    const a = ra.reply, b = rb.reply, msg = ra.msg
    if (!a || !b || !msg) { failures++; console.log(`all ${i}: missing ${!a ? "Atlas" : ""} ${!b ? "Bolt" : ""}`); continue }
    add("all.first_client_ms", Math.min(a.at, b.at) - st.t0)
    add("all.both_client_ms", Math.max(a.at, b.at) - st.t0)
    add("all.both_server_ms", Math.max(a.f.at, b.f.at) - msg.f.at)
    add("all.spread_ms", Math.abs(a.f.at - b.f.at))
    const second = a.f.at >= b.f.at ? { p: ann, c: ann.chief!.id, r: a } : { p: ben, c: ben.chief!.id, r: b }
    stages("all.second", msg.f.at, await runFor(second.p, second.c, group, msg.f.at), second.r.f.at)
    console.log(`all ${i}: first ${Math.min(a.at, b.at) - st.t0} ms, both ${Math.max(a.at, b.at) - st.t0} ms, spread ${Math.abs(a.f.at - b.f.at)} ms`)
    await sleep(3000)
  }
  sa.ws.close()
} catch (e) {
  failures++
  console.log(`runner error: ${String(e).slice(0, 300)}`)
} finally {
  if (!keep && secrets.STACK_SECRET_SERVER_KEY) {
    if (stackTeam) await fetch(`${STACK}/teams/${stackTeam}`, { method: "DELETE", headers: serverHeaders, body: "{}" })
    for (const p of people) await fetch(`${STACK}/users/${p.stackUser}`, { method: "DELETE", headers: serverHeaders, body: "{}" })
  }
  const table = Object.entries(series).map(([k, xs]) => ({ series: k, n: xs.length, p50: pct(xs, 50), p95: pct(xs, 95), max: Math.max(...xs) }))
  console.log("\nseries                              n    p50    p95    max")
  for (const r of table) console.log(`${r.series.padEnd(34)} ${String(r.n).padStart(3)} ${String(r.p50).padStart(6)} ${String(r.p95).padStart(6)} ${String(r.max).padStart(6)}`)
  if (reportPath) writeFileSync(reportPath, JSON.stringify({ run, api: API, at: new Date().toISOString(), runs: RUNS, failures, table, series, rows }, null, 2))
  process.exit(failures === 0 ? 0 : 1)
}
