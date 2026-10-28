import type { Env } from "../env.ts"
import { callerOf, type Fail } from "../home-attachments.ts"
import { chiefOwnedBy } from "./brain-io.ts"
import { brainName, type ConfigPatch } from "./brain-do.ts"
import { childObject } from "./brain-spawn.ts"
import { githubOf } from "../chief-brain-cc/github.ts"
import { chiefMainConversation } from "../domains/user-chief.ts"
import { PEER_NAME, PEER_TEXT_MAX } from "./brain-turn.ts"
import { type AppendBody, type AppendResult, type ImportBody, type ImportFail, type ImportStatus, MAX_IMPORT_BODY, type UndoBody, type UndoResult, parseAppendBody, parseImportBody } from "./memory-import.ts"

/**
 * HTTP routes of the Chief brain (outside the op catalog, like the keyed acpmux start):
 *
 *   GET  /v1/chiefs/<agent>/brain           the owner: settings and state
 *   PUT  /v1/chiefs/<agent>/brain           the owner: {enabled?, model?, effort?, compactor_model?, role?, personality?, instructions?, chiefs?}
 *        model: fake | claude-opus-5-5 | claude-sonnet-5-5 | claude-haiku-5-5 | openrouter:<vendor>/<model> | @cf/<vendor>/<model>
 *        effort: off | minimal | low | medium | high | xhigh | max (default low); model-gateway/routes.ts says who may use which
 *   POST /v1/chiefs/<agent>/peer            the owner: {from, text, key}: a message from one of the owner's Chiefs on
 *        another machine (the agent hub's forward, brain-turn.ts peerNote), queued in the chief's main conversation
 *   GET  /v1/chiefs/<agent>/github          the owner: the Chief's GitHub login (who, kind, scopes, expiry; never the token)
 *   POST /v1/chiefs/<agent>/github          the owner: {action: login | pat | mac | app | logout | status, ...} (chief-brain-cc/github.ts)
 *   GET  /v1/chiefs/<agent>/memory?conversation=<id>   the owner: the memory copy's state {count, nodes, state}
 *   PUT  /v1/chiefs/<agent>/memory?conversation=<id>   the owner: one batch of a Mac Chief's memory copy (memory-import.ts)
 *   GET  /v1/chiefs/<agent>/runs?conversation=<id>&before=<ms>&limit=<n>   a member: the chief's runs there, newest first
 *   GET  /v1/chiefs/<agent>/runs/<run>?conversation=<id>&after_seq=<n>   a member: {run, steps, has_more}
 *        (a subagent's run `sub_<n>` is read from its own object, brain-spawn.ts)
 *
 * Run and Step are the trajectory wire's JSON (brain-runs.ts); members also get each change live as
 * a `conversation-run-changed` frame on the conversation socket.
 *
 * "The owner" is the chief's owner_user (MuxDO head) with a session, or an install whose grant
 * covers mutate-own; a chief's own token never changes its brain.
 */
export const CHIEF_BRAIN_PATH = /^\/v1\/chiefs\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/(brain|github|memory|peer|runs(?:\/((?:run|sub)_[0-9]{1,15}))?)$/

const NO_STORE = { "cache-control": "no-store" }
const fail = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: NO_STORE })
const ok = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
const PATCH_KEYS = new Set(["enabled", "model", "effort", "compactor_model", "role", "personality", "instructions", "chiefs"])

export const handleChiefBrain = async (request: Request, env: Env, agent: string, path: string, run: string | undefined): Promise<Response> => {
  if (env.CHIEF_BRAIN_ENABLED !== "1") return fail({ status: 404, code: "not_found", message: "Chief brains are off on this deployment" })
  const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(agent))
  if (path === "memory") return handleMemoryImport(request, env, agent, brain)
  if (path === "peer") return handlePeer(request, env, agent)
  if (path === "github") return handleGithub(request, env, agent)
  if (path === "brain") {
    if (request.method !== "GET" && request.method !== "PUT") return fail({ status: 405, code: "method_not_allowed", message: "GET or PUT" })
    const caller = await callerOf(request, env, "read")
    if ("status" in caller) return fail(caller)
    const p = caller.principal
    if (p.kind !== "session" && !(p.grant_classes ?? []).includes("mutate-own")) return fail({ status: 403, code: "auth.forbidden", message: "grant does not cover mutate-own" })
    const owned = await chiefOwnedBy(env, agent, p)
    if (!owned) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner changes its brain" })
    if (request.method === "GET") return ok(await brain.status())
    const body = (await request.json().catch(() => null)) as Record<string, unknown> | null
    if (!body || typeof body !== "object" || Array.isArray(body) || Object.keys(body).some((k) => !PATCH_KEYS.has(k))) {
      return fail({ status: 400, code: "validation.invalid", message: `body is an object of ${[...PATCH_KEYS].join(", ")}` })
    }
    const r = await brain.configure(agent, owned.owner, body as ConfigPatch)
    return r.ok ? ok(r.config) : fail({ status: r.code === "auth.forbidden" ? 403 : r.code.startsWith("chief_") ? 409 : 400, code: r.code, message: r.message })
  }
  if (request.method !== "GET") return fail({ status: 405, code: "method_not_allowed", message: "GET" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const url = new URL(request.url)
  const num = (k: string) => {
    const v = url.searchParams.has(k) ? Number(url.searchParams.get(k)) : Number.NaN
    return Number.isFinite(v) ? v : undefined
  }
  // One answer for a run (or conversation) that does not exist and one the caller may not see: no existence probe.
  const hidden = { status: 404, code: "not_found", message: "no such run" }
  const member = async (conversation: string) => {
    const conv = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(conversation)) as unknown as { readOp(e: string, p: unknown, op: string, params: unknown): Promise<{ ok: boolean }> }
    return (await conv.readOp(conversation, caller.principal, "conversation.history", { limit: 1 })).ok
  }
  const conversation = url.searchParams.get("conversation") ?? ""
  if (!/^conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26}$/.test(conversation)) return fail({ status: 400, code: "validation.invalid", message: "conversation is required" })
  // Membership first: a non-member never reaches (or creates) a brain object.
  if (!(await member(conversation))) return fail(hidden)
  const convBrain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(agent, conversation)))
  if (!run) return ok(await convBrain.runs(conversation, num("before"), Math.min(Math.max(Math.floor(num("limit") ?? 20), 1), 100)))
  // Step tool inputs are JSON values (unknown), which the RPC stub type cannot express: read the shape here.
  const sub = /^sub_([0-9]{1,15})$/.exec(run)
  if (sub && !(await (convBrain as unknown as { spawned(n: number): Promise<boolean> }).spawned(Number(sub[1])))) return fail(hidden)
  const archived = sub ? await (convBrain as unknown as { spawnRun(n: number, after: number): Promise<{ run: { conversation: string } } | null> }).spawnRun(Number(sub[1]), Math.max(0, Math.floor(num("after_seq") ?? 0))) : null
  if (archived) return archived.run.conversation === conversation ? ok(archived) : fail(hidden)
  const holder = sub ? env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(childObject(agent, conversation, Number(sub[1])))) : convBrain
  const found = (await (holder.run(run, Math.max(0, Math.floor(num("after_seq") ?? 0)), 500) as unknown as Promise<{ run: { conversation: string } } | null>))
  return found && found.run.conversation === conversation ? ok(found) : fail(hidden)
}

type MemoryBrain = {
  status(): Promise<{ config: { enabled: boolean; brain_impl?: string } }>
  memoryImportStatus(): Promise<ImportStatus>
  memoryImport(body: ImportBody | AppendBody | UndoBody, brainOn: boolean): Promise<ImportStatus | ImportFail | (AppendResult & { ok: true }) | (UndoResult & { ok: true })>
}

/**
 * The memory copy of a Mac Chief into this Chief's brain of `conversation` (memory-import.ts): the
 * owner's session (or an install with mutate-own), a member of the conversation. The brain's own
 * on/off lives in the Chief's settings object (`brain`): a copy runs only while it is off.
 */
const handleMemoryImport = async (request: Request, env: Env, agent: string, settings: unknown): Promise<Response> => {
  if (request.method !== "GET" && request.method !== "PUT") return fail({ status: 405, code: "method_not_allowed", message: "GET or PUT" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const p = caller.principal
  if (p.kind !== "session" && !(p.grant_classes ?? []).includes("mutate-own")) return fail({ status: 403, code: "auth.forbidden", message: "grant does not cover mutate-own" })
  if (!(await chiefOwnedBy(env, agent, p))) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner copies its memory" })
  // Only the Chief's own main conversation (the owner and the Chief): a private memory never goes into a shared conversation's brain.
  const conversation = new URL(request.url).searchParams.get("conversation") ?? ""
  if (conversation !== chiefMainConversation(agent)) return fail({ status: 400, code: "validation.invalid", message: "conversation is the Chief's main conversation" })
  const conv = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(conversation)) as unknown as { readOp(e: string, p: unknown, op: string, params: unknown): Promise<{ ok: boolean }> }
  if (!(await conv.readOp(conversation, p, "conversation.history", { limit: 1 })).ok) return fail({ status: 404, code: "not_found", message: "no such conversation" })
  const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(agent, conversation))) as unknown as MemoryBrain
  if (request.method === "GET") return ok(await brain.memoryImportStatus())
  const text = await capped(request, MAX_IMPORT_BODY)
  if (text === null) return fail({ status: 413, code: "validation.too_large", message: `one batch is at most ${MAX_IMPORT_BODY} bytes` })
  let raw: unknown = null
  try {
    raw = JSON.parse(text)
  } catch {}
  const appendBody = parseAppendBody(raw)
  const body = appendBody ?? parseImportBody(raw)
  if ("ok" in body) return fail(body)
  const config = (await (settings as MemoryBrain).status()).config
  if (config.brain_impl !== undefined && config.brain_impl !== "pi") return fail({ status: 409, code: "brain_impl", message: "this Chief's brain keeps its own memory elsewhere" })
  const on = config.enabled
  const r = await brain.memoryImport(body, on)
  if ("ok" in r && r.ok === false) return fail(r)
  return ok(r)
}

/** The body as text, or null when it is longer than `max` bytes (read with a cap: a large body is never held whole). */
const capped = async (request: Request, max: number): Promise<string | null> => {
  if (Number(request.headers.get("content-length") ?? 0) > max) return null
  if (!request.body) return ""
  const reader = request.body.getReader()
  const chunks: Array<Uint8Array> = []
  let size = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > max) return void (await reader.cancel().catch(() => undefined)), null
    chunks.push(value)
  }
  const all = new Uint8Array(size)
  let at = 0
  for (const c of chunks) all.set(c, (at += c.byteLength) - c.byteLength)
  return new TextDecoder().decode(all)
}

/** POST /v1/chiefs/<agent>/peer: the owner (a session, or an install whose grant covers mutate-own) forwards a peer Chief's message. */
const handlePeer = async (request: Request, env: Env, agent: string): Promise<Response> => {
  if (request.method !== "POST") return fail({ status: 405, code: "method_not_allowed", message: "POST" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const p = caller.principal
  if (p.kind !== "session" && !(p.grant_classes ?? []).includes("mutate-own")) return fail({ status: 403, code: "auth.forbidden", message: "grant does not cover mutate-own" })
  const owned = await chiefOwnedBy(env, agent, p)
  if (!owned) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner forwards peer messages" })
  const body = (await request.json().catch(() => null)) as { from?: unknown; text?: unknown; key?: unknown } | null
  const from = typeof body?.from === "string" ? body.from : ""
  const text = typeof body?.text === "string" ? body.text.trim() : ""
  const key = typeof body?.key === "string" ? body.key : ""
  if (!PEER_NAME.test(from) || !text || text.length > PEER_TEXT_MAX || !/^[A-Za-z0-9._:-]{1,128}$/.test(key)) {
    return fail({ status: 400, code: "validation.invalid", message: `body is {from: a hub name, text: 1 to ${PEER_TEXT_MAX} characters, key: 1 to 128 of A-Z a-z 0-9 . _ : -}` })
  }
  const conversation = chiefMainConversation(agent)
  const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(agent, conversation)))
  const r = await brain.peerNote({ agent, owner: owned.owner, conversation, from, text, key })
  return "skipped" in r ? fail({ status: 409, code: "chief_not_answering", message: `the chief does not answer now (${r.skipped})` }) : ok({ conversation, queued: r.queued })
}

/**
 * GET/POST /v1/chiefs/<agent>/github (chief-brain-cc/github.ts): the owner reads or changes the Chief's GitHub
 * login from Chief settings, with no turn. The answer is the status, never the token.
 */
const handleGithub = async (request: Request, env: Env, agent: string): Promise<Response> => {
  if (request.method !== "GET" && request.method !== "POST") return fail({ status: 405, code: "method_not_allowed", message: "GET or POST" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const p = caller.principal
  if (p.kind !== "session" && !(p.grant_classes ?? []).includes("mutate-own")) return fail({ status: 403, code: "auth.forbidden", message: "grant does not cover mutate-own" })
  if (!(await chiefOwnedBy(env, agent, p))) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner sees or changes its GitHub login" })
  const body = request.method === "GET" ? { action: "status" } : ((await request.json().catch(() => null)) as Record<string, unknown> | null)
  if (!body || typeof body !== "object" || Array.isArray(body) || typeof body.action !== "string" || /^github_|^wait$/.test(body.action)) {
    return fail({ status: 400, code: "validation.invalid", message: "body is {action: login | pat | mac | app | logout | status, ...}" })
  }
  const r = await githubOf(env, agent).ccGithub(agent, body, false)
  if (r.status === 200) return ok(r.json)
  const message = String((r.json as { error?: unknown } | null)?.error ?? "the GitHub call failed")
  return fail({ status: r.status, code: r.status === 503 ? "unavailable" : r.status === 400 ? "validation.invalid" : "upstream", message })
}
