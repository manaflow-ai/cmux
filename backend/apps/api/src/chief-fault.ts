import type { Env } from "./env.ts"
import { callerOf, type Fail } from "./home-attachments.ts"
import { chiefOwnedBy } from "./chief-brain/brain-io.ts"
import { brainName } from "./chief-brain/brain-do.ts"

/**
 * Test-only fault hooks for the Chief conformance harness (crash in the middle of a turn):
 *
 *   POST /v1/chiefs/<agent>/fault {conversation, target: "brain" | "container"}   the Chief's owner
 *
 * - `brain`: the pi brain object of that conversation (ChiefBrainDO `<agent>/<conversation>`) aborts
 *   itself, as an eviction does: memory state is lost, storage stays, pi-durable resumes the turn.
 * - `container`: the opencode brain's container (OpencodeBrainDO `<agent>`) is stopped at once, as a
 *   container crash; the host starts a new one and sends the same wake again.
 *
 * On only where CHIEF_FAULT_HOOKS is "1" AND the deployment is not staging or production (tests and
 * the development env). Off, the route answers 404 like any unknown path and the objects refuse.
 */
export const FAULT_PATH = /^\/v1\/chiefs\/(agent_[0-9A-HJKMNP-TV-Z]{26})\/fault$/

export const faultHooksOn = (env: Env): boolean => env.CHIEF_FAULT_HOOKS === "1" && env.ENVIRONMENT !== "staging" && env.ENVIRONMENT !== "production"

/** Inside a brain object: refuse unless the hooks are on. */
export const assertFaultHooks = (env: Env): void => {
  if (!faultHooksOn(env)) throw new Error("fault hooks are off on this deployment")
}

const NO_STORE = { "cache-control": "no-store" }
const fail = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message } }, { status: f.status, headers: NO_STORE })

export const handleFault = async (request: Request, env: Env, agent: string): Promise<Response> => {
  if (!faultHooksOn(env)) return fail({ status: 404, code: "not_found", message: "not found" })
  if (request.method !== "POST") return fail({ status: 405, code: "method_not_allowed", message: "POST" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  if (!(await chiefOwnedBy(env, agent, caller.principal))) return fail({ status: 403, code: "auth.forbidden", message: "only the chief's owner" })
  const body = (await request.json().catch(() => null)) as { conversation?: unknown; target?: unknown } | null
  const conversation = typeof body?.conversation === "string" ? body.conversation : ""
  if (!/^conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26}$/.test(conversation)) return fail({ status: 400, code: "validation.invalid", message: "conversation is required" })
  const at = Date.now()
  if (body?.target === "brain") {
    const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(agent, conversation))) as unknown as { fault(): Promise<void> }
    // The object aborts itself: the RPC that asked fails with that abort, which is the expected answer.
    await brain.fault().catch(() => undefined)
    return Response.json({ ok: true, value: { target: "brain", at } }, { headers: NO_STORE })
  }
  if (body?.target === "container") {
    if (!env.OPENCODE_BRAIN_DO) return fail({ status: 409, code: "no_container", message: "this deployment has no opencode brain" })
    const o = env.OPENCODE_BRAIN_DO.get(env.OPENCODE_BRAIN_DO.idFromName(agent)) as unknown as { fault(): Promise<{ stopped: boolean }> }
    const r = await o.fault()
    return r.stopped ? Response.json({ ok: true, value: { target: "container", at } }, { headers: NO_STORE }) : fail({ status: 409, code: "no_container", message: "no container is running for this chief" })
  }
  return fail({ status: 400, code: "validation.invalid", message: 'target is "brain" or "container"' })
}
