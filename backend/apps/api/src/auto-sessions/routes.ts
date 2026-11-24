import type { Env } from "../env.ts"
import { callerFor, isRefused, type Refused } from "./callers.ts"
import { MAX_EVENTS_PAGE, type EventIn } from "./events.ts"
import { answer, bodyOf, bounded, bytesOf, CHAT_ID, count, DEVICE, fail, HARNESS, hex, invalid, json, MACHINE, MESSAGE_ID, noContent, notFound, rawJson, refusal, repoOf, TEAM, titleOf, WRITER_HELP, writerOf } from "./http.ts"
import { mayUseTeam, type AutoListCursor } from "./index-do.ts"
import { MAX_CHUNK_BYTES, MAX_EVENTS_PER_POST, MAX_EVENTS_POST_BYTES, MAX_INBOX_TEXT_BYTES, MAX_MANIFEST_BYTES, MAX_WAIT_MS, type AutoCaller, type AutoSessionView } from "./model.ts"
import { NOT_A_LAPTOP } from "./devices.ts"
import { SHA256_HEX } from "./snapshots.ts"

/**
 * Auto mode's routes (plans/cmux-next/auto-mode/DESIGN.md "Cloud API"; the store is session-do.ts and index-do.ts).
 * Errors are `{error: {code, message}}`; a refusal about a chat the caller may see also carries `session`.
 *
 * Callers (callers.ts): the owner (a signed-in session or a person's install), and a machine (the bearer of a VM
 * install bound to a Cloud machine of the owner; its holder is `vm:<that machine>`).
 *
 *   GET  /v1/auto-sessions/machine              owner    -> {team, machine}: the one the owner named, else one of their own Cloud machines in
 *                                                        the caller's team that the store picks and keeps for that team; 404 auto.no_machine
 *                                                        when they have none there
 *   PUT  /v1/auto-sessions/machine              owner    {team, machine} -> {team, machine}; one per owner, for every team's chats; it replaces every pick
 *   GET  /v1/auto-sessions?limit=&cursor=       owner    -> {sessions, nextCursor}
 *   POST /v1/auto-sessions                      owner    {title?, harness, repo: {remote, branch}, firstMessage: {id, text}}
 *                                                        -> 201 {session}: the Auto machine holds it, assignment `create`; 409 auto.no_machine
 *                                                        only when the owner named none and has no Cloud machine of their own
 *   GET  /v1/auto-sessions/assignments?timeoutMs=  machine  -> {assignments: [{kind, session}]}, held until one exists or the deadline
 *   PUT  /v1/auto-sessions/:id                  owner    {auto, title, harness, device, keepInCloud?, repo?} -> {session}; the first call makes it,
 *                                                        held by `device:<device>` at epoch 1; `{auto: false}` closes it, 409 auto.held_in_cloud while a machine holds it
 *   GET  /v1/auto-sessions/:id                  owner, machine -> {session}
 *   GET  /v1/auto-sessions/:id/wait?after=<version>&timeoutMs=  owner -> {session} once its version passes `after`, or at the deadline (at most 25 s)
 *   POST /v1/auto-sessions/:id/lease            owner, machine {holder, epoch, needsRun, standby?} -> {session, role: holder|standby|lost, leaseMs}
 *   POST /v1/auto-sessions/:id/release          holder   {holder, epoch} -> {session}: parked, or the standby laptop's
 *   POST /v1/auto-sessions/:id/events           holder   {holder, epoch, events: [{seq, record}]} (at most 256, 1 MiB) -> {lastSeq}; 409 auto.seq_gap with lastSeq
 *   GET  /v1/auto-sessions/:id/events?after=<seq>&limit=  owner, machine -> {events, lastSeq}
 *   PUT  /v1/auto-sessions/:id/chunks/:sha256   holder   bytes (at most 1 MiB), x-cmux-auto-holder, x-cmux-auto-epoch -> 204; 400 auto.chunk_mismatch
 *   GET  /v1/auto-sessions/:id/chunks/:sha256   owner, machine -> bytes
 *   POST /v1/auto-sessions/:id/snapshot         holder   {holder, epoch, manifest} -> {snapshot}; 409 auto.snapshot_incomplete with `missing`
 *   GET  /v1/auto-sessions/:id/snapshot         owner, machine -> {snapshot, manifest}; 404 auto.no_snapshot
 *   POST /v1/auto-sessions/:id/inbox            owner    {id, text} -> {state: delivered|resuming|queued, session}; the same id again answers the same
 *   GET  /v1/auto-sessions/:id/inbox?after=<n>  holder   -> {messages: [{n, id, text, at}]}
 *   POST /v1/auto-sessions/:id/inbox/ack        holder   {holder, epoch, through} -> {session}
 *   POST /v1/auto-sessions/:id/keep             owner    {keepInCloud} -> {session}
 *   POST /v1/auto-sessions/:id/assignment/ack   machine  {holder, epoch} -> {session}
 *
 * A write that names a holder or epoch that is not current is refused 409 auto.not_holder or auto.stale_epoch. A holder
 * write (and a PUT with `auto: true`) from an install that holds no chat (a phone, a browser session) is refused 403
 * auto.not_a_laptop; one that names a `device:` another of the owner's installs named first in the chat, 403
 * auto.wrong_device (devices.ts).
 * The routes answer 404 where AUTO_SESSION_DO is unbound (production, until Auto mode ships there).
 */
export const AUTO_SESSIONS_PATH = /^\/v1\/auto-sessions(?:\/([^/]+)(?:\/([^/]+)(?:\/([^/]+))?)?)?$/

type Caller = AutoCaller & { readonly team: string | null }
type Call = { readonly request: Request; readonly env: Env; readonly url: URL; readonly id: string; readonly last: string | undefined; readonly by: Caller }
/** `holds`: the route is a holder write, which only a laptop or a machine makes (devices.ts). */
type Route = { readonly allow: "owner" | "machine" | "either"; readonly holds?: true; readonly run: (c: Call) => Promise<Response> }

const stub = (env: Env, owner: string, id: string) => env.AUTO_SESSION_DO!.get(env.AUTO_SESSION_DO!.idFromName(`${owner}/${id}`))
const indexOf = (env: Env, owner: string) => env.AUTO_SESSION_INDEX_DO!.get(env.AUTO_SESSION_INDEX_DO!.idFromName(owner))
const chat = (c: Call) => stub(c.env, c.by.owner, c.id)
const who = (c: Call): AutoCaller => (c.by.kind === "machine" ? { kind: "machine", owner: c.by.owner, machine: c.by.machine } : { kind: "owner", owner: c.by.owner, install: c.by.install ?? null })
/** A holder write from an owner's install that holds no chat (a phone, a browser session): refused before its body is read. */
const noLaptop = (c: Call): Response | null => (c.by.kind === "owner" && !c.by.install ? refusal(NOT_A_LAPTOP) : null)
const session = (s: AutoSessionView) => ({ session: s })
const refused = (w: Refused): Response => fail(w.status, w.code, w.message)

const open = async (c: Call): Promise<Response> => {
  const b = await bodyOf(c.request)
  if (b instanceof Response) return b
  if (typeof b.auto !== "boolean") return invalid("auto: true to keep the chat in Auto mode, false to turn it off")
  if (!b.auto) return answer(await chat(c).open(who(c), c.id, c.by.team, null), session)
  const laptop = noLaptop(c)
  if (laptop) return laptop
  const title = titleOf(b.title)
  if (title === null) return invalid("title: the chat's title (at most 200 characters)")
  if (typeof b.harness !== "string" || !HARNESS.test(b.harness)) return invalid("harness: the agent the chat runs (lowercase letters, digits, _ . -, at most 32)")
  if (typeof b.device !== "string" || !DEVICE.test(b.device)) return invalid("device: this laptop's id (letters, digits, _ . -, at most 64)")
  if (b.keepInCloud !== undefined && typeof b.keepInCloud !== "boolean") return invalid("keepInCloud: true or false")
  const repo = b.repo === undefined ? undefined : b.repo === null ? null : repoOf(b.repo)
  if (repo === null && b.repo !== null) return invalid("repo: {remote, branch}")
  return answer(await chat(c).open(who(c), c.id, c.by.team, { title, harness: b.harness, device: b.device, ...(typeof b.keepInCloud === "boolean" ? { keepInCloud: b.keepInCloud } : {}), ...(repo === undefined ? {} : { repo }) }), session)
}

const lease = async (c: Call): Promise<Response> => {
  const b = await bodyOf(c.request)
  if (b instanceof Response) return b
  const w = writerOf(b.holder, b.epoch)
  if (!w) return invalid(WRITER_HELP)
  const standby = b.standby === true
  if (typeof b.needsRun !== "boolean" && !standby) return invalid("needsRun: whether the chat has a turn running, a prompt queued or a background task at work")
  if (b.standby !== undefined && typeof b.standby !== "boolean") return invalid("standby: true for a laptop that has the chat and does not hold it")
  return answer(await chat(c).lease(who(c), { ...w, needsRun: b.needsRun === true, standby }), (v) => v)
}

/** A body that only names its writer, handed to `run`. */
const written = async (c: Call, run: (holder: string, epoch: number, b: Record<string, unknown>) => Promise<Response>, max?: number): Promise<Response> => {
  const b = await bodyOf(c.request, max)
  if (b instanceof Response) return b
  const w = writerOf(b.holder, b.epoch)
  return w ? run(w.holder, w.epoch, b) : invalid(WRITER_HELP)
}

const postEvents = (c: Call): Promise<Response> =>
  written(c, async (holder, epoch, b) => {
    if (!Array.isArray(b.events) || b.events.length > MAX_EVENTS_PER_POST) return invalid(`events: at most ${MAX_EVENTS_PER_POST} of {seq, record}`)
    const events: Array<EventIn> = []
    for (const e of b.events as Array<{ seq?: unknown; record?: unknown } | null>) {
      const seq = count(e?.seq)
      if (seq === null || seq < 1 || e?.record === undefined) return invalid("events: each is {seq, record}, seq from 1")
      events.push({ seq, record: JSON.stringify(e.record) })
    }
    return answer(await chat(c).appendEvents(who(c), holder, epoch, events), (v) => v)
  }, MAX_EVENTS_POST_BYTES)

const getEvents = async (c: Call): Promise<Response> => {
  const r = await chat(c).events(who(c), bounded(c.url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER), bounded(c.url.searchParams.get("limit"), MAX_EVENTS_PAGE, MAX_EVENTS_PAGE))
  // Records go out as the text they were stored as.
  return r.ok ? rawJson(`{"events":[${r.value.events.map((e) => `{"seq":${e.seq},"record":${e.record}}`).join(",")}],"lastSeq":${r.value.lastSeq}}`) : refusal(r)
}

const putChunk = async (c: Call): Promise<Response> => {
  const w = writerOf(c.request.headers.get("x-cmux-auto-holder"), c.request.headers.get("x-cmux-auto-epoch"))
  if (!w) return invalid(`x-cmux-auto-holder and x-cmux-auto-epoch: ${WRITER_HELP}`)
  const bytes = await bytesOf(c.request, MAX_CHUNK_BYTES)
  if (bytes instanceof Response) return bytes
  const r = await chat(c).putChunk(who(c), w.holder, w.epoch, c.last!, bytes.buffer)
  return r.ok ? noContent() : refusal(r)
}

const getChunk = async (c: Call): Promise<Response> => {
  const r = await chat(c).chunk(who(c), c.last!)
  return r.ok ? new Response(r.value, { headers: { "cache-control": "no-store", "content-type": "application/octet-stream" } }) : refusal(r)
}

const postSnapshot = (c: Call): Promise<Response> =>
  written(c, async (holder, epoch, b) => {
    const m = b.manifest as { lastSeq?: unknown } | null
    const lastSeq = m !== null && typeof m === "object" && !Array.isArray(m) ? count(m.lastSeq) : null
    if (lastSeq === null) return invalid("manifest: the snapshot manifest, an object whose lastSeq is the last event it covers")
    const text = JSON.stringify(m)
    if (text.length > MAX_MANIFEST_BYTES) return fail(413, "auto.too_large", `a manifest is at most ${MAX_MANIFEST_BYTES} bytes`)
    return answer(await chat(c).putSnapshot(who(c), holder, epoch, text, lastSeq), (v) => v)
  }, MAX_MANIFEST_BYTES + 4096)

const getSnapshot = async (c: Call): Promise<Response> => {
  const r = await chat(c).snapshot(who(c))
  return r.ok ? rawJson(`{"snapshot":${r.value.snapshot},"manifest":${r.value.manifest}}`) : refusal(r)
}

const postInbox = async (c: Call): Promise<Response> => {
  const b = await bodyOf(c.request, MAX_INBOX_TEXT_BYTES * 4 + 4096)
  if (b instanceof Response) return b
  if (typeof b.id !== "string" || !MESSAGE_ID.test(b.id)) return invalid("id: the message's id (letters, digits, _ . : -, at most 128); the same id is taken once")
  if (typeof b.text !== "string" || b.text.length === 0 || b.text.length > MAX_INBOX_TEXT_BYTES) return invalid(`text: the message (at most ${MAX_INBOX_TEXT_BYTES} characters)`)
  return answer(await chat(c).post(c.by.owner, { id: b.id, text: b.text }), (v) => v)
}

/** A chat's routes, by method and the path after its id (`chunks/:` stands for a chunk's name). */
const ROUTES: Record<string, Route> = {
  "GET ": { allow: "either", run: async (c) => answer(await chat(c).get(who(c)), session) },
  "PUT ": { allow: "owner", run: open },
  "GET wait": { allow: "owner", run: async (c) => answer(await chat(c).wait(c.by.owner, bounded(c.url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER), bounded(c.url.searchParams.get("timeoutMs"), MAX_WAIT_MS, MAX_WAIT_MS)), session) },
  "POST lease": { allow: "either", holds: true, run: lease },
  "POST release": { allow: "either", holds: true, run: (c) => written(c, async (holder, epoch) => answer(await chat(c).release(who(c), holder, epoch), session)) },
  "POST events": { allow: "either", holds: true, run: postEvents },
  "GET events": { allow: "either", run: getEvents },
  "PUT chunks/:": { allow: "either", holds: true, run: putChunk },
  "GET chunks/:": { allow: "either", run: getChunk },
  "POST snapshot": { allow: "either", holds: true, run: postSnapshot },
  "GET snapshot": { allow: "either", run: getSnapshot },
  "POST inbox": { allow: "owner", run: postInbox },
  "GET inbox": { allow: "either", run: async (c) => answer(await chat(c).inbox(who(c), bounded(c.url.searchParams.get("after"), 0, Number.MAX_SAFE_INTEGER)), (v) => v) },
  "POST inbox/ack": {
    allow: "either",
    holds: true,
    run: (c) =>
      written(c, async (holder, epoch, b) => {
        const through = count(b.through)
        return through === null ? invalid("through: the number of the last message the holder took") : answer(await chat(c).ackInbox(who(c), holder, epoch, through), session)
      })
  },
  "POST keep": {
    allow: "owner",
    run: async (c) => {
      const b = await bodyOf(c.request)
      if (b instanceof Response) return b
      return typeof b.keepInCloud === "boolean" ? answer(await chat(c).keep(c.by.owner, b.keepInCloud), session) : invalid("keepInCloud: true or false")
    }
  },
  "POST assignment/ack": { allow: "machine", run: (c) => written(c, async (holder, epoch) => answer(await chat(c).ackAssignment(who(c), holder, epoch), session)) }
}
const METHODS = ["GET", "PUT", "POST"]

const forChat = async (request: Request, env: Env, id: string, sub: string | undefined, last: string | undefined): Promise<Response> => {
  const path = sub === "chunks" && last !== undefined && SHA256_HEX.test(last) ? "chunks/:" : last === undefined ? (sub ?? "") : `${sub}/${last}`
  const route = ROUTES[`${request.method} ${path}`]
  if (!route) return METHODS.some((m) => ROUTES[`${m} ${path}`]) ? fail(405, "method_not_allowed", METHODS.filter((m) => ROUTES[`${m} ${path}`]).join(" or ")) : notFound()
  const by = await callerFor(request, env, route.allow, request.method !== "GET")
  if (isRefused(by)) return refused(by)
  const c = { request, env, url: new URL(request.url), id, last, by }
  return (route.holds && noLaptop(c)) || route.run(c)
}

const encodeCursor = (c: AutoListCursor) => btoa(JSON.stringify(c)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const decodeCursor = (value: string): AutoListCursor | null => {
  try {
    const v = JSON.parse(atob(value.replace(/-/g, "+").replace(/_/g, "/"))) as { createdAt?: unknown; id?: unknown }
    return Number.isSafeInteger(v.createdAt) && typeof v.id === "string" ? { createdAt: v.createdAt as number, id: v.id } : null
  } catch {
    return null
  }
}

/** `GET /v1/auto-sessions` (the owner's Auto chats, newest first) and `POST` (a chat started with no laptop). */
const collection = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "GET" && request.method !== "POST") return fail(405, "method_not_allowed", "GET or POST")
  const by = await callerFor(request, env, "owner", request.method === "POST")
  if (isRefused(by)) return refused(by)
  if (request.method === "GET") {
    const url = new URL(request.url)
    const cursor = url.searchParams.get("cursor")
    const before = cursor ? decodeCursor(cursor) : undefined
    if (before === null) return invalid("cursor: use the nextCursor of the previous page")
    const page = await indexOf(env, by.owner).list(by.owner, Math.max(1, bounded(url.searchParams.get("limit"), 50, 100)), before)
    return json({ sessions: page.sessions, nextCursor: page.next ? encodeCursor(page.next) : null })
  }
  const b = await bodyOf(request, MAX_INBOX_TEXT_BYTES * 4 + 4096)
  if (b instanceof Response) return b
  const title = b.title === undefined ? "" : titleOf(b.title)
  if (title === null) return invalid("title: the chat's title (at most 200 characters)")
  if (typeof b.harness !== "string" || !HARNESS.test(b.harness)) return invalid("harness: the agent the chat runs (lowercase letters, digits, _ . -, at most 32)")
  const repo = repoOf(b.repo)
  if (!repo) return invalid("repo: {remote, branch}, the repository and branch the chat works in")
  const first = b.firstMessage as { id?: unknown; text?: unknown } | null | undefined
  if (!first || typeof first.id !== "string" || !MESSAGE_ID.test(first.id) || typeof first.text !== "string" || first.text.length === 0 || first.text.length > MAX_INBOX_TEXT_BYTES) return invalid(`firstMessage: {id, text}, the chat's first message (at most ${MAX_INBOX_TEXT_BYTES} characters)`)
  if (env.CLOUD_MUTATION_LIMIT && !(await env.CLOUD_MUTATION_LIMIT.limit({ key: `auto-session:${by.owner}` })).success) return fail(429, "rate_limited", "too many new chats just now; retry in a minute")
  // The id is the first message's: a retry after a lost answer reaches the chat it made.
  const id = `as_${(await hex(`${by.owner}\u0000${first.id}`)).slice(0, 20)}`
  return answer(await stub(env, by.owner, id).createCloud(by.owner, id, by.team, { title, harness: b.harness, repo, message: { id: first.id, text: first.text } }), session, 201)
}

/**
 * `GET` and `PUT /v1/auto-sessions/machine`: the owner's Auto machine. `GET` answers the one they named, else the
 * one the store picked among their own Cloud machines of the caller's team (it looks there when none is kept
 * yet); a pick made for another team's chats is not answered. `PUT` names one for all the owner's chats: it
 * replaces every pick, and the chats that were waiting for a machine go to it.
 */
const machineSetting = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "GET" && request.method !== "PUT") return fail(405, "method_not_allowed", "GET or PUT")
  const by = await callerFor(request, env, "owner", request.method === "PUT")
  if (isRefused(by)) return refused(by)
  const index = indexOf(env, by.owner)
  if (request.method === "GET") {
    const set = await index.autoMachine(by.owner, by.team)
    return set ? json(set) : fail(404, "auto.no_machine", "the owner has no Cloud machine for Auto chats")
  }
  const b = await bodyOf(request)
  if (b instanceof Response) return b
  if (typeof b.team !== "string" || !TEAM.test(b.team)) return invalid("team: the team the machine belongs to")
  if (typeof b.machine !== "string" || !MACHINE.test(b.machine)) return invalid("machine: the Cloud machine id (letters, digits, _ -, at most 64)")
  if (!(await mayUseTeam(env, by.owner, b.team))) return fail(403, "auth.forbidden", "no access to this team's machines")
  const machine = { team: b.team, machine: b.machine }
  const named = await index.nameMachine(by.owner, machine)
  if (named === "not_own") return fail(403, "auth.forbidden", "the Auto machine must be one of your own Cloud machines in that team, not a classic one")
  if (named === "unknown") return fail(503, "owner.unreachable", "cmux Cloud could not say whose machine that is; retry")
  return json(machine)
}

/** `GET /v1/auto-sessions/assignments`: what the calling machine has not acked, held until there is one or the deadline. */
const assignments = async (request: Request, env: Env): Promise<Response> => {
  if (request.method !== "GET") return fail(405, "method_not_allowed", "GET")
  const by = await callerFor(request, env, "machine", false)
  if (isRefused(by)) return refused(by)
  if (by.kind !== "machine") return notFound()
  return json({ assignments: await indexOf(env, by.owner).assignments(by.machine, bounded(new URL(request.url).searchParams.get("timeoutMs"), MAX_WAIT_MS, MAX_WAIT_MS)) })
}

const decoded = (segment: string): string => {
  try {
    return decodeURIComponent(segment)
  } catch {
    return segment
  }
}

export const handleAutoSessions = async (request: Request, env: Env, m: RegExpMatchArray): Promise<Response> => {
  if (!env.AUTO_SESSION_DO || !env.AUTO_SESSION_INDEX_DO) return notFound()
  try {
    const [, named, sub, last] = m
    if (named === undefined) return await collection(request, env)
    // A client may percent-encode the `:` of a chat id.
    const first = decoded(named)
    if (first === "machine" || first === "assignments") return sub !== undefined ? notFound() : first === "machine" ? await machineSetting(request, env) : await assignments(request, env)
    return CHAT_ID.test(first) ? await forChat(request, env, first, sub, last) : notFound()
  } catch (e) {
    console.error(JSON.stringify({ msg: "auto_sessions.route_failed", error: String(e).slice(0, 200) }))
    return fail(503, "auto.unavailable", "the Auto mode store is unavailable; retry")
  }
}
