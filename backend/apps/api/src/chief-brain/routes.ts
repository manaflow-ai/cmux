import type { Env } from "../env.ts"
import { callerOf, type Fail } from "../home-attachments.ts"
import { chiefOwnedBy } from "./brain-io.ts"
import { brainName, type ConfigPatch } from "./brain-do.ts"
import { childObject } from "./brain-spawn.ts"

/**
 * HTTP routes of the Chief brain (outside the op catalog, like the keyed acpmux start):
 *
 *   GET  /v1/chiefs/<agent>/brain           the owner: settings and state
 *   PUT  /v1/chiefs/<agent>/brain           the owner: {enabled?, model?, effort?, compactor_model?, role?, personality?, instructions?, chiefs?}
 *        model: fake | claude-opus-5-5 | claude-sonnet-5-5 | claude-haiku-5-5 | openrouter:<vendor>/<model> | @cf/<vendor>/<model>
 *        effort: off | minimal | low | medium | high | xhigh | max (default low); model-gateway/routes.ts says who may use which
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
export const CHIEF_BRAIN_PATH = /^\/v1\/chiefs\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/(brain|runs(?:\/((?:run|sub)_[0-9]{1,15}))?)$/

const NO_STORE = { "cache-control": "no-store" }
const fail = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: NO_STORE })
const ok = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })
const PATCH_KEYS = new Set(["enabled", "model", "effort", "compactor_model", "role", "personality", "instructions", "chiefs"])

export const handleChiefBrain = async (request: Request, env: Env, agent: string, path: string, run: string | undefined): Promise<Response> => {
  if (env.CHIEF_BRAIN_ENABLED !== "1") return fail({ status: 404, code: "not_found", message: "Chief brains are off on this deployment" })
  const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(agent))
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
