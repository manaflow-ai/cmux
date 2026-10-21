import type { Env } from "../env.ts"
import { callerOf, type Fail } from "../home-attachments.ts"
import { chiefOwnedBy } from "../chief-brain/brain-io.ts"
import { brainModel, modelRefusal, opencodeRuns } from "../model-gateway/routes.ts"

/**
 * HTTP routes of implementation O (outside the op catalog, like the P brain's):
 *
 *   GET|PUT /v1/chiefs/<agent>/brain-impl          the owner: {impl: "pi" | "opencode"} (default pi)
 *   POST    /v1/chief-opencode/<agent>/cp          the Chief's container: CP JSON-RPC (container token)
 *   POST    /v1/chief-opencode/<agent>/gateway/v1/messages   the container: model gateway stub (container token)
 *   GET     /v1/chiefs/<agent>/runs[...]           served here instead of by the P brain when the Chief runs O
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
const muxOf = (env: Env, agent: string) => env.MUX_DO.get(env.MUX_DO.idFromName(agent)) as unknown as { setBrainImpl(impl: "pi" | "opencode"): Promise<void>; brainImplOf(): Promise<string> }

export const handleBrainImpl = async (request: Request, env: Env, agent: string): Promise<Response> => {
  if (!opencodeOn(env)) return fail({ status: 404, code: "not_found", message: "the opencode brain is off on this deployment" })
  if (request.method !== "GET" && request.method !== "PUT") return fail({ status: 405, code: "method_not_allowed", message: "GET or PUT" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const p = caller.principal
  if (p.kind !== "session" && !(p.grant_classes ?? []).includes("mutate-own")) return fail({ status: 403, code: "auth.forbidden", message: "grant does not cover mutate-own" })
  const owned = await chiefOwnedBy(env, agent, p)
  if (!owned) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner chooses its brain" })
  const brain = brainOf(env, agent)
  if (request.method === "GET") return ok({ impl: (await muxOf(env, agent).brainImplOf()) === "opencode" ? "opencode" : "pi" })
  const body = (await request.json().catch(() => null)) as { impl?: unknown } | null
  if (body?.impl !== "pi" && body?.impl !== "opencode") return fail({ status: 400, code: "validation.invalid", message: 'impl is "pi" or "opencode"' })
  // Moving a Chief that is on to opencode moves its turns to brainModel (host.ts): a paid model this owner may not use is refused here, not at each turn.
  if (body.impl === "opencode" && opencodeRuns(env)) {
    const { config } = await (env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(agent)) as unknown as { status(): Promise<{ config: { enabled: boolean; model: string } }> }).status()
    const refused = config.enabled ? modelRefusal(env, owned.owner, { model: brainModel(config.model) }) : null
    if (refused) return fail({ status: 409, code: refused.code, message: refused.message })
  }
  // The routing truth first (MuxDO), then the brain object (owner binding, container stop on pi).
  await muxOf(env, agent).setBrainImpl(body.impl)
  return ok(await brain.setImpl(agent, owned.owner, body.impl))
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
  if ((await muxOf(env, agent).brainImplOf()) !== "opencode") return p()
  const brain = brainOf(env, agent)
  if (!run) return ok(await brain.runs(conversation, num("before"), Math.min(Math.max(Math.floor(num("limit") ?? 20), 1), 100)))
  const found = (await (brain.run(run, Math.max(0, Math.floor(num("after_seq") ?? 0)), 500) as unknown as Promise<{ run: { conversation: string } } | null>))
  return found && found.run.conversation === conversation ? ok(found) : fail(hidden)
}
