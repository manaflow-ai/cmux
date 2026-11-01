/**
 * Chief multiplayer against the deployed staging API (plans/cmux-next/chief-done.md checks 1, 2, 4, 8, 9).
 * Two throwaway people (Stack sign-up, `chief-mp-<run>-<a|b>@example.test`, never a real person), each
 * the way their own Mac signs in: a Stack session, user.ensure, an install key and its token.
 *
 *   1  both sign in and get Home (user.ensure, their main Chief, inbox.list)
 *   2  one Stack team (made with the server key, mirrored into TeamDO by the Stack webhook): they see
 *      each other in the team, DM by user id and make a group
 *   4  live on both sides: each person's conversation socket sees the other's message, typing, an
 *      edit, a reaction and the read cursor, with no reload; both inboxes count unread
 *   8  each person's Chief (model `fake`: no model cost) joins the group, added by its own owner only
 *   9  a Chief runs its owner's effectful request; the other person's request to it gets the owner
 *      approval answer and nothing runs (the brain's tool reply says so)
 *
 *   bun backend/scripts/chief-multiplayer-staging.ts [--env staging] [--report PATH] [--keep]
 *
 * Reads ~/.secrets/cmuxterm-dev.env (project id, publishable client key; STACK_SECRET_SERVER_KEY to make
 * the team and, at the end, delete the team and both users unless --keep). Never prints a token or key.
 */
import { readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { createHash } from "node:crypto"

const arg = (n: string, d: string) => (process.argv.includes(n) ? process.argv[process.argv.indexOf(n) + 1]! : d)
const envName = arg("--env", "staging")
if (envName !== "staging") throw new Error(`env ${envName} is not allowed: this runner only touches staging`)
const API = "https://cloud-api-staging.cmux.dev"
const WS = API.replace(/^https/, "wss")
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
const code = (r: Reply) => r.body?.error?.code as string | undefined

type Row = { check: string; name: string; pass: boolean; detail: string; ms?: number }
const rows: Array<Row> = []
const record = (check: string, name: string, pass: boolean, detail = "", ms?: number) => {
  rows.push({ check, name, pass, detail, ...(ms === undefined ? {} : { ms }) })
  console.log(`${pass ? "PASS" : "FAIL"}  [${check}] ${name}${ms === undefined ? "" : ` (${ms} ms)`}${detail ? ` -- ${detail}` : ""}`)
}
const poll = async <T>(f: () => Promise<T | undefined>, ms = 60_000, every = 750): Promise<{ value: T | undefined; ms: number }> => {
  const start = Date.now()
  while (Date.now() - start < ms) {
    const v = await f()
    if (v !== undefined) return { value: v, ms: Date.now() - start }
    await sleep(every)
  }
  return { value: undefined, ms: Date.now() - start }
}

interface Person { tag: string; name: string; email: string; stackUser: string; session: string; user: string; team: string; chief?: { id: string; main_conversation: string; display_name: string } }
const signUp = async (tag: string, name: string): Promise<Person> => {
  const email = `chief-mp-${run}-${tag}@example.test`
  const up = await fetch(`${STACK}/auth/password/sign-up`, { method: "POST", headers: clientHeaders, body: JSON.stringify({ email, password: `Mp-${crypto.randomUUID()}!` }) })
  if (!up.ok) throw new Error(`Stack sign-up ${tag}: ${up.status} ${(await up.text()).slice(0, 200)}`)
  const j = (await up.json()) as { access_token: string; user_id: string }
  await fetch(`${STACK}/users/${j.user_id}`, { method: "PATCH", headers: serverHeaders, body: JSON.stringify({ display_name: name }) })
  const ensured = await op(j.access_token, "user.ensure", {})
  if (!ok(ensured)) throw new Error(`user.ensure ${tag}: ${ensured.raw.slice(0, 200)}`)
  return { tag, name, email, stackUser: j.user_id, session: j.access_token, user: ensured.body.value.id, team: ensured.body.value.personal_team }
}

/** A conversation socket as the Mac's daemon opens it. */
const socket = async (p: Person, conversation: string) => {
  const ws = new WebSocket(`${WS}/v1/wire/conv/${conversation}`, { headers: { authorization: `Bearer ${p.session}` }, protocols: ["cmux.wire.v1"] } as any)
  const frames: Array<{ at: number; f: any }> = []
  ws.addEventListener("message", (e) => { try { frames.push({ at: Date.now(), f: JSON.parse(String(e.data)) }) } catch {} })
  await new Promise<void>((resolve, reject) => { ws.addEventListener("open", () => resolve()); ws.addEventListener("error", () => reject(new Error(`socket ${p.tag}`))) })
  ws.send(JSON.stringify({ t: "subscribe" }))
  const until = async (pred: (f: any) => boolean, ms = 20_000): Promise<{ at: number; f: any } | undefined> => (await poll(async () => frames.find((x) => pred(x.f)), ms, 50)).value
  return { ws, frames, until, send: (f: unknown) => ws.send(JSON.stringify(f)) }
}
const textPart = (t: string, runs?: unknown) => ({ type: "text", text: t, ...(runs ? { runs } : {}) })
const send = async (p: Person, conversation: string, part: unknown) => {
  const key = crypto.randomUUID()
  const t0 = Date.now()
  const r = await op(p.session, "message.send", { conversation, client_msg_id: key, parts: [part] }, key)
  return { ok: ok(r), id: r.body?.value?.message_id as string | undefined, seq: r.body?.value?.seq as number | undefined, t0, raw: r.raw }
}
const history = async (p: Person, conversation: string) => ((await read(p.session, "conversation.history", { conversation, limit: 100 })).body?.value?.messages ?? []) as Array<any>
const mention = (c: NonNullable<Person["chief"]>, text: string) => textPart(`@${c.display_name} ${text}`, [{ start: 0, length: c.display_name.length + 1, mention: c.id }])

const people: Array<Person> = []
let stackTeam: string | undefined
try {
  // ---- 1: two people sign in; each gets Home and a main Chief.
  const ann = await signUp("a", `Ann ${run}`); people.push(ann)
  const ben = await signUp("b", `Ben ${run}`); people.push(ben)
  for (const p of [ann, ben]) {
    const c = await op(p.session, "chief.create", { display_name: p.tag === "a" ? "Atlas" : "Bolt" }, `chief-default-${run}-${p.tag}`)
    p.chief = c.body?.value
    const inbox = await read(p.session, "inbox.list", { limit: 20 })
    record("1", `${p.tag}: signs in, Home inbox answers, main Chief made`, ok(c) && ok(inbox) && !!p.chief?.id, `${p.user} chief ${p.chief?.id ?? code(c)}`)
  }

  // ---- 2: one Stack team; the webhook mirrors it; they reach each other by id.
  if (!secrets.STACK_SECRET_SERVER_KEY) throw new Error("no STACK_SECRET_SERVER_KEY: cannot make the team")
  const team = await fetch(`${STACK}/teams`, { method: "POST", headers: serverHeaders, body: JSON.stringify({ display_name: `chief-mp-${run}`, creator_user_id: ann.stackUser }) })
  stackTeam = ((await team.json()) as { id?: string }).id
  const joined = stackTeam ? await fetch(`${STACK}/team-memberships/${stackTeam}/${ben.stackUser}`, { method: "POST", headers: serverHeaders, body: "{}" }) : undefined
  record("2", "Stack team made with both people", !!stackTeam && !!joined?.ok, `stack team ${stackTeam} membership ${joined?.status}`)
  const cmuxTeam = `team_${hex20(`stack-team:${projectId}:${stackTeam}`)}`
  let lastMembers = ""
  const mirrored = await poll(async () => {
    const r = await read(ben.session, "team.members.list", { team: cmuxTeam }, cmuxTeam)
    lastMembers = r.raw.slice(0, 200)
    const users = ((r.body?.value?.members ?? []) as Array<{ user: string }>).map((m) => m.user)
    return users.includes(ann.user) && users.includes(ben.user) ? users : undefined
  }, 90_000, 2000)
  record("2", "TeamDO mirrors the Stack team (webhook) with both members", !!mirrored.value, mirrored.value ? cmuxTeam : `${cmuxTeam}: ${lastMembers}`, mirrored.ms)
  const dmOpen = await op(ann.session, "dm.open", { peer: ben.user })
  const dm = dmOpen.body?.value?.conversation?.id as string | undefined
  record("2", "Ann opens a DM with Ben by user id (team reach)", !!dm, dm ?? `${code(dmOpen)} ${dmOpen.raw.slice(0, 160)}`)

  // ---- 4: the DM is live on both Macs.
  if (dm) {
    const sa = await socket(ann, dm)
    const sb = await socket(ben, dm)
    const m1 = await send(ann, dm, textPart(`hi Ben ${run}`))
    const seen = await sb.until((f) => f.t === "event" && JSON.stringify(f).includes(`hi Ben ${run}`))
    record("4", "DM: Ben's socket gets Ann's message live", !!seen, "", seen ? seen.at - m1.t0 : undefined)
    sb.send({ t: "typing", on: true })
    const typing = await sa.until((f) => f.t === "conversation-typing" && f.participant === ben.user && f.on === true)
    record("4", "DM: Ann's socket sees Ben typing", !!typing)
    const m2 = await send(ben, dm, textPart("hey Ann"))
    const back = await sa.until((f) => f.t === "event" && JSON.stringify(f).includes("hey Ann"))
    record("4", "DM: Ann's socket gets Ben's reply live", !!back, "", back ? back.at - m2.t0 : undefined)
    const edit = await op(ann.session, "message.edit", { conversation: dm, message_id: m1.id, parts: [textPart(`hi Ben ${run} (edited)`)] })
    const edited = await sb.until((f) => f.t === "event" && JSON.stringify(f).includes("(edited)"))
    record("4", "DM: Ann's edit reaches Ben live", ok(edit) && !!edited, ok(edit) ? "" : edit.raw.slice(0, 160))
    const react = await op(ben.session, "reaction.add", { conversation: dm, message_id: m1.id, part_index: 0, reaction: { emoji: "👍" } })
    const reacted = await sa.until((f) => JSON.stringify(f).includes("👍"))
    record("4", "DM: Ben's reaction reaches Ann live", ok(react) && !!reacted, ok(react) ? "" : react.raw.slice(0, 160))
    const unread = await poll(async () => {
      const e = ((await read(ben.session, "inbox.list", { limit: 50 })).body?.value?.entries ?? []).find((x: any) => x.conversation === dm)
      return e && e.last_seq >= (m2.seq ?? 0) ? e : undefined
    }, 30_000)
    record("4", "DM: Ben's inbox lists the DM with Ann", !!unread.value, JSON.stringify(unread.value ? { kind: unread.value.kind, unread: unread.value.unread } : null), unread.ms)
    const cur = await op(ann.session, "read_cursor.set", { conversation: dm, seq: m2.seq })
    const cursor = await sb.until((f) => JSON.stringify(f).includes("read") && JSON.stringify(f).includes(ann.user) && f.t !== "event")
    record("4", "DM: Ann's read cursor reaches Ben (read state)", ok(cur) && !!cursor, ok(cur) ? "" : cur.raw.slice(0, 160))
    sa.ws.close(); sb.ws.close()
  }

  // ---- 2 + 8: a group with both people; each adds only their own Chief.
  const created = await op(ann.session, "conversation.create", { kind: "group", title: `Launch ${run}`, participants: [{ id: ann.user, kind: "human", display_name: ann.name }, { id: ben.user, kind: "human", display_name: ben.name }, { id: ann.chief!.id, kind: "agent", agent_class: "mux", display_name: "Atlas" }] })
  const group = created.body?.value?.conversation?.id as string | undefined
  record("2", "Ann makes a group with Ben and her Chief", !!group, group ?? created.raw.slice(0, 200))
  if (group) {
    const notHers = await op(ann.session, "participants.add", { conversation: group, participant: { id: ben.chief!.id, kind: "agent", agent_class: "mux", display_name: "Bolt" } })
    record("8", "Ann cannot add Ben's Chief", code(notHers) === "forbidden", code(notHers) ?? "added")
    const his = await op(ben.session, "participants.add", { conversation: group, participant: { id: ben.chief!.id, kind: "agent", agent_class: "mux", display_name: "Bolt" } })
    record("8", "Ben adds his own Chief to Ann's group", ok(his), ok(his) ? "" : his.raw.slice(0, 200))
    for (const p of [ann, ben]) {
      const on = await http("PUT", `/v1/chiefs/${p.chief!.id}/brain`, p.session, { enabled: true, model: "fake", compactor_model: "fake" })
      record("8", `${p.tag}: Chief brain on (model fake)`, on.status === 200, on.status === 200 ? "" : on.raw.slice(0, 200))
    }
    const sa = await socket(ann, group)
    const sb = await socket(ben, group)
    const g1 = await send(ben, group, textPart(`group hello ${run}`))
    const gseen = await sa.until((f) => f.t === "event" && JSON.stringify(f).includes(`group hello ${run}`))
    record("4", "group: Ann's socket gets Ben's message live", !!gseen, "", gseen ? gseen.at - g1.t0 : undefined)

    const chiefSaid = async (p: Person, chief: string, after: number, match: (t: string) => boolean, ms = 90_000) =>
      poll(async () => (await history(p, group)).find((m) => m.author === chief && m.seq > after && match(JSON.stringify(m.parts))), ms, 1500)

    // A mention wakes only that Chief; its answer reaches the other person's socket.
    const q = await send(ben, group, mention(ben.chief!, `what is on my plate ${run}?`))
    const bolt1 = await chiefSaid(ann, ben.chief!.id, q.seq ?? 0, (t) => t.includes(`what is on my plate ${run}`))
    record("8", "Bolt answers Ben's mention in the group (seen by Ann)", !!bolt1.value, "", bolt1.ms)
    const live = await sa.until((f) => f.t === "event" && JSON.stringify(f).includes(ben.chief!.id) && JSON.stringify(f).includes(`plate ${run}`), 5_000)
    record("4", "group: Bolt's answer reached Ann's socket live", !!live)
    const atlasQuiet = (await history(ann, group)).filter((m) => m.author === ann.chief!.id)
    record("8", "Atlas stays quiet on a message not for it (wake_policy auto)", atlasQuiet.length === 0, `${atlasQuiet.length} messages`)

    // 9: Ann asks Ben's Chief for an effect: the approval rule.
    const ask = await send(ann, group, mention(ben.chief!, `tool:spawn ${JSON.stringify({ tasks: [`deploy for ann ${run}`] })}`))
    const refused = await chiefSaid(ann, ben.chief!.id, ask.seq ?? 0, (t) => t.includes("owner approval required") || t.includes("Started"))
    const rtext = JSON.stringify(refused.value?.parts ?? "")
    record("9", "Ann's effect request to Ben's Chief gets the owner-approval answer, nothing starts", rtext.includes("owner approval required") && !rtext.includes("Started"), rtext.slice(0, 160), refused.ms)
    // 9: Ann's own request to her own Chief runs.
    const own = await send(ann, group, mention(ann.chief!, `tool:spawn ${JSON.stringify({ tasks: [`ann's own task ${run}`] })}`))
    const ran = await chiefSaid(ann, ann.chief!.id, own.seq ?? 0, (t) => t.includes("Started") || t.includes("owner approval required"))
    const otext = JSON.stringify(ran.value?.parts ?? "")
    record("9", "Ann's effect request to her own Chief runs (no approval card)", otext.includes("Started") && !otext.includes("owner approval required"), otext.slice(0, 160), ran.ms)
    // 9: Ben confirms on his own Chief: it runs as Ben's.
    const conf = await send(ben, group, mention(ben.chief!, `tool:spawn ${JSON.stringify({ tasks: [`approved by ben ${run}`] })}`))
    const ranB = await chiefSaid(ben, ben.chief!.id, conf.seq ?? 0, (t) => t.includes("Started") || t.includes("owner approval required") || t.includes("reply to:"))
    const btext = JSON.stringify(ranB.value?.parts ?? "")
    record("9", "Ben's own confirmation to his Chief runs", btext.includes("tool said: Started"), btext.slice(0, 160), ranB.ms)

    // The group owner sets the reply rule; under `all` both Chiefs answer one person's message, and the group goes quiet after.
    const benSet = await op(ben.session, "conversation.settings.set", { conversation: group, wake_policy: "all" })
    const annSet = await op(ann.session, "conversation.settings.set", { conversation: group, wake_policy: "all" })
    record("8", "only the group owner sets Chiefs Reply (all)", !ok(benSet) && ok(annSet), `ben ${code(benSet) ?? "ok"}, ann ${code(annSet) ?? "ok"}`)
    const st = await send(ben, group, textPart(`status everyone ${run}?`))
    const both = await poll(async () => {
      const h = await history(ann, group)
      const a = h.find((m) => m.author === ann.chief!.id && m.reply_to?.message_id === st.id)
      const b = h.find((m) => m.author === ben.chief!.id && m.reply_to?.message_id === st.id)
      return a && b ? [a, b] : undefined
    }, 150_000, 2000)
    const after = (await history(ann, group)).filter((m) => m.seq > (st.seq ?? 0)).map((m) => [m.author === ann.chief!.id ? "Atlas" : m.author === ben.chief!.id ? "Bolt" : m.author, m.reply_to?.message_id === st.id, JSON.stringify(m.parts).slice(0, 140)])
    record("8", "under all, both Chiefs answer Ben's message", !!both.value, both.value ? "" : JSON.stringify(after).slice(0, 900), both.ms)
    const count1 = (await history(ann, group)).length
    await sleep(20_000)
    const count2 = (await history(ann, group)).length
    record("8", "the two Chiefs do not wake each other (no new messages in 20 s)", count1 === count2, `${count1} -> ${count2}`)
    record("4", "both people see the same group transcript", JSON.stringify((await history(ann, group)).map((m) => m.id)) === JSON.stringify((await history(ben, group)).map((m) => m.id)))
    sa.ws.close(); sb.ws.close()
  }
} catch (e) {
  record("run", "runner error", false, String(e).slice(0, 300))
} finally {
  if (!keep && secrets.STACK_SECRET_SERVER_KEY) {
    if (stackTeam) console.log(`cleanup: Stack team ${stackTeam} delete -> ${(await fetch(`${STACK}/teams/${stackTeam}`, { method: "DELETE", headers: serverHeaders, body: "{}" })).status}`)
    for (const p of people) console.log(`cleanup: Stack user ${p.stackUser} (${p.email}) delete -> ${(await fetch(`${STACK}/users/${p.stackUser}`, { method: "DELETE", headers: serverHeaders, body: "{}" })).status}`)
  }
  const failed = rows.filter((r) => !r.pass)
  console.log(`\n${rows.length - failed.length}/${rows.length} passed (run ${run})`)
  if (reportPath) writeFileSync(reportPath, JSON.stringify({ run, api: API, at: new Date().toISOString(), rows }, null, 2))
  process.exit(failed.length === 0 ? 0 : 1)
}
