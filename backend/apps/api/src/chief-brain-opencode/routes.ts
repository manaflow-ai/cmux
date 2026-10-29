import type { Env } from "../env.ts"
import { callerOf, type Fail } from "../home-attachments.ts"
import { chiefOwnedBy } from "../chief-brain/brain-io.ts"
import { brainModel, modelRefusal, opencodeRuns } from "../model-gateway/routes.ts"
import { durableOn } from "../mux-wake-delivery.ts"

/**
 * HTTP routes of implementation O (outside the op catalog, like the P brain's):
 *
 *   GET|PUT /v1/chiefs/<agent>/brain-impl          the owner: {impl: "pi" | "opencode" | "durable"} (default pi; each only where it runs)
 *   POST    /v1/chief-opencode/<agent>/cp          the Chief's container: CP JSON-RPC (container token)
 *   POST    /v1/chief-opencode/<agent>/gateway/v1/messages   the container: model gateway stub (container token)
 *   GET     /v1/chiefs/<agent>/runs[...]           served here instead of by the P brain when the Chief runs O or D
 *
 * Off unless CHIEF_OPENCODE_ENABLED is "1". The container token is random per container start and
 * known only to OpencodeBrainDO and that container; identity is the DO's, never the request's.
 */
export const OPENCODE_IMPL_PATH = /^\/v1\/chiefs\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/brain-impl$/
export const OPENCODE_HOST_PATH = /^\/v1\/chief-opencode\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/(cp|gateway\/v1\/messages)$/

const NO_STORE = { "cache-control": "no-store" }
const fail = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: NO_STORE })
const ok = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
export const opencodeOn = (env: Env) => env.CHIEF_OPENCODE_ENABLED === "1" && env.OPENCODE_BRAIN_DO !== undefined
const brainOf = (env: Env, agent: string) => env.OPENCODE_BRAIN_DO!.get(env.OPENCODE_BRAIN_DO!.idFromName(agent))
/** MuxDO keeps the Chief's brain_impl: the one routing truth (mux-do.ts setBrainImpl). */
const muxOf = (env: Env, agent: string) => env.MUX_DO.get(env.MUX_DO.idFromName(agent)) as unknown as { setBrainImpl(impl: Impl): Promise<void>; brainImplOf(): Promise<string> }
type Impl = "pi" | "opencode" | "durable"
/** The brains a Chief may pick on this deployment: P always, O and D where they run. */
const impls = (env: Env): ReadonlyArray<Impl> => ["pi", ...(opencodeOn(env) ? (["opencode"] as const) : []), ...(durableOn(env) ? (["durable"] as const) : [])]
/** Where both a D and a P brain exist for one Chief conversation (D's first wake copied P's memory). */
type RunsReader = { run(id: string, afterSeq: number, limit: number): Promise<{ run: { conversation: string } } | null>; runs(conversation: string, before: number | undefined, limit: number): Promise<{ runs: Array<unknown>; has_more: boolean }> }
const durableOf = (env: Env, agent: string, conversation: string) => env.CHIEF_DURABLE_DO!.get(env.CHIEF_DURABLE_DO!.idFromName(`${agent}/${conversation}`)) as unknown as RunsReader

export const handleBrainImpl = async (request: Request, env: Env, agent: string): Promise<Response> => {
  const allowed = impls(env)
  if (allowed.length === 1) return fail({ status: 404, code: "not_found", message: "this deployment runs only the pi brain" })
  if (request.method !== "GET" && request.method !== "PUT") return fail({ status: 405, code: "method_not_allowed", message: "GET or PUT" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const p = caller.principal
  if (p.kind !== "session" && !(p.grant_classes ?? []).includes("mutate-own")) return fail({ status: 403, code: "auth.forbidden", message: "grant does not cover mutate-own" })
  const owned = await chiefOwnedBy(env, agent, p)
  if (!owned) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner chooses its brain" })
  if (request.method === "GET") {
    const impl = (await muxOf(env, agent).brainImplOf()) as Impl
    return ok({ impl: allowed.includes(impl) ? impl : "pi" })
  }
  const body = (await request.json().catch(() => null)) as { impl?: unknown } | null
  const impl = allowed.find((i) => i === body?.impl)
  if (!impl) return fail({ status: 400, code: "validation.invalid", message: `impl is one of ${allowed.map((i) => `"${i}"`).join(", ")}` })
  // Moving a Chief that is on to opencode moves its turns to brainModel (host.ts): a paid model this owner may not use is refused here, not at each turn.
  if (impl === "opencode" && opencodeRuns(env)) {
    const { config } = await (env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(agent)) as unknown as { status(): Promise<{ config: { enabled: boolean; model: string } }> }).status()
    const refused = config.enabled ? modelRefusal(env, owned.owner, { model: brainModel(config.model) }) : null
    if (refused) return fail({ status: 409, code: refused.code, message: refused.message })
  }
  // The routing truth first (MuxDO), then the opencode brain object (owner binding, container stop when not O).
  await muxOf(env, agent).setBrainImpl(impl)
  if (!opencodeOn(env)) return ok({ impl })
  const o = await brainOf(env, agent).setImpl(agent, owned.owner, impl === "opencode" ? "opencode" : "pi")
  return ok({ ...o, impl })
}

/** Container -> host: the DO checks the container token. */
export const handleOpencodeHost = (request: Request, env: Env, agent: string): Promise<Response> | Response => {
  if (!opencodeOn(env) || request.method !== "POST") return new Response("not found", { status: 404 })
  if (!request.headers.get("authorization") && !request.headers.get("x-api-key")) return new Response("unauthorized", { status: 401 })
  return brainOf(env, agent).fetch(request)
}

/**
 * GET /v1/chiefs/<agent>/runs[/<run>]?conversation=, where O is on: a member of the conversation reads
 * the Chief's runs. Membership is checked before any brain object is asked; a Chief on P goes to the
 * P route (`p`), which checks again.
 */
export const handleOpencodeRuns = async (request: Request, env: Env, agent: string, run: string | undefined, p: () => Promise<Response>): Promise<Response> => {
  if (request.method !== "GET") return fail({ status: 405, code: "method_not_allowed", message: "GET" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const url = new URL(request.url)
  const num = (k: string) => {
    const v = url.searchParams.has(k) ? Number(url.searchParams.get(k)) : Number.NaN
    return Number.isFinite(v) ? v : undefined
  }
  const hidden = { status: 404, code: "not_found", message: "no such run" }
  const conversation = url.searchParams.get("conversation") ?? ""
  if (!/^conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26}$/.test(conversation)) return fail({ status: 400, code: "validation.invalid", message: "conversation is required" })
  const conv = env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(conversation)) as unknown as { readOp(e: string, p: unknown, op: string, params: unknown): Promise<{ ok: boolean }> }
  if (!(await conv.readOp(conversation, caller.principal, "conversation.history", { limit: 1 })).ok) return fail(hidden)
  const impl = await muxOf(env, agent).brainImplOf()
  if (impl === "durable" && durableOn(env)) {
    // D's runs first; a run from before the move (P's) is read from P, and the list goes on with P's runs.
    const d = durableOf(env, agent, conversation)
    if (run) {
      const found = await d.run(run, Math.max(0, Math.floor(num("after_seq") ?? 0)), 500)
      return found && found.run.conversation === conversation ? ok(found) : p()
    }
    const limit = Math.min(Math.max(Math.floor(num("limit") ?? 20), 1), 100)
    const mine = await d.runs(conversation, num("before"), limit)
    if (mine.has_more || mine.runs.length === limit) return ok(mine)
    const older = (await (await p()).json().catch(() => null)) as { ok?: boolean; value?: { runs: Array<unknown>; has_more: boolean } } | null
    const rest = older?.ok && older.value ? older.value : { runs: [], has_more: false }
    const all = [...mine.runs, ...rest.runs]
    return ok({ runs: all.slice(0, limit), has_more: all.length > limit || rest.has_more })
  }
  if (impl !== "opencode" || !opencodeOn(env)) return p()
  const brain = brainOf(env, agent)
  if (!run) return ok(await brain.runs(conversation, num("before"), Math.min(Math.max(Math.floor(num("limit") ?? 20), 1), 100)))
  const found = (await (brain.run(run, Math.max(0, Math.floor(num("after_seq") ?? 0)), 500) as unknown as Promise<{ run: { conversation: string } } | null>))
  return found && found.run.conversation === conversation ? ok(found) : fail(hidden)
}
