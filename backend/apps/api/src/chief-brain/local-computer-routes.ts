import type { Env } from "../env.ts"
import { callerOf, type Fail } from "../home-attachments.ts"
import { sandboxesOf } from "../chief-brain-cc/sandbox.ts"
import { ccConfigured } from "../chief-brain-cc/vm.ts"
import { LOCAL_COMPUTER_CAP, localComputerKey, localRegistryOf } from "../chief-brain-cc/local-computer.ts"

/**
 * The computer of a Chief that runs on its owner's Mac (chief-brain-cc/local-computer.ts), the same routes and answers
 * as a Cloud Chief's (`/v1/chiefs/<agent>/computer…`, routes.ts) under the Mac's own id for that Chief:
 *
 *   GET  /v1/local-chiefs/<chief>/computer          the status: {used, entitled, acting?, provisioning?, provision_error?, computer, screen, control}
 *   GET  /v1/local-chiefs/<chief>/computer/screen   a JPEG while it runs; 409 computer.asleep, 404 with none
 *   POST /v1/local-chiefs/<chief>/computer/control  {action: provision | take_over | hand_back}; provision answers 202
 *        {provisioning: true} while it is made, 200 {computer} for the one it has, 403 cloud.plan.required without a Cloud
 *        plan, 409 computer.local_limit when the owner's other local Chiefs hold LOCAL_COMPUTER_CAP computers, 409
 *        computer.unavailable where the Claude Code route is not configured
 *   POST /v1/local-chiefs/<chief>/computer/input    the person's input while they hold it (as the Cloud Chief's route)
 *   POST /v1/local-chiefs/<chief>/computer/act      the Chief's own verb from its tools on the Mac (`cloud_computer`):
 *        {op: screenshot | windows | click | move | drag | scroll | type | key | open | control | request_human | hand_back
 *        | start, …} as `chief-vm computer` takes it; refused with computer.human_has_control while the person holds it
 *
 * Every route takes only the owner's own signed-in session (403 computer.user_origin_required for an install grant or a
 * Chief's token): the computer is keyed by the session's user, so nobody reaches another person's, and a Chief with no
 * computer answers 404 alike for every caller.
 */
export const LOCAL_CHIEF_COMPUTER_PATH = /^\/v1\/local-chiefs\/([A-Za-z0-9_-]{1,64})\/computer(?:\/(screen|control|input|act))?$/

const NO_STORE = { "cache-control": "no-store" }
const fail = (f: Fail) => Response.json({ ok: false, error: { code: f.code, message: f.message, ...f.extra } }, { status: f.status, headers: NO_STORE })
const ok = (value: unknown, status = 200) => Response.json({ ok: true, value }, { status, headers: NO_STORE })
/** A server-side failure's text can name the provider: the person and the Chief read this sentence instead. */
const neutral = (status: number, message: string | undefined): string => (status >= 500 ? "the computer did not answer" : message ?? "the computer did not answer")
const ACT_OPS = new Set(["screenshot", "windows", "click", "move", "drag", "scroll", "type", "key", "open", "control", "request_human", "hand_back", "start"])

export const handleLocalChiefComputer = async (request: Request, env: Env, chief: string, sub: string | undefined): Promise<Response> => {
  if (env.CHIEF_BRAIN_ENABLED !== "1") return fail({ status: 404, code: "not_found", message: "Chief brains are off on this deployment" })
  const reads = sub === undefined || sub === "screen"
  if (request.method !== (reads ? "GET" : "POST")) return fail({ status: 405, code: "method_not_allowed", message: reads ? "GET" : "POST" })
  const caller = await callerOf(request, env, "read")
  if ("status" in caller) return fail(caller)
  const p = caller.principal
  if (p.kind !== "session" || p.agent !== undefined || !p.user) return fail({ status: 403, code: "computer.user_origin_required", message: "only the owner's signed-in session reads or drives a Chief's computer" })
  const user = p.user
  const key = localComputerKey(user, chief)
  const sandboxes = sandboxesOf(env, key)
  if (sub === undefined) return ok(await sandboxes.ccComputerStatus(key, user))
  if (sub === "screen") {
    const shot = await sandboxes.ccComputerScreen(key)
    if (shot.status !== 200) return fail({ status: shot.status, code: shot.status === 409 ? "computer.asleep" : shot.status === 404 ? "not_found" : "computer.unreachable", message: shot.error, ...(shot.state ? { extra: { state: shot.state } } : {}) })
    const bytes = Uint8Array.from(atob(shot.image), (c) => c.charCodeAt(0))
    return new Response(bytes, { headers: { "content-type": "image/jpeg", ...NO_STORE } })
  }
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null
  if (!body || typeof body !== "object" || Array.isArray(body)) return fail({ status: 400, code: "validation.invalid", message: "body is a JSON object" })
  if (sub === "control") {
    if (body.action === "provision") {
      if (!ccConfigured(env)) return fail({ status: 409, code: "computer.unavailable", message: "a Chief's computer is not available on this server" })
      const slot = await localRegistryOf(env, user).ccLocalComputerReserve(user, chief)
      if (!slot.ok) return fail({ status: 409, code: "computer.local_limit", message: `your Chiefs on your Mac have ${LOCAL_COMPUTER_CAP} computers already; one must end before another is made`, extra: { cap: LOCAL_COMPUTER_CAP } })
      const r = await sandboxes.ccComputerProvision(key, user)
      if (r.status === 200) return ok({ computer: r.computer })
      if (r.status === 202) return ok({ provisioning: true }, 202)
      // Refused (no plan) or failed: nothing holds the slot, so it is free again at once.
      await localRegistryOf(env, user).ccLocalComputerRelease(chief)
      return fail({ status: r.status, code: r.code, message: neutral(r.status, r.error) })
    }
    if (body.action === "delete") {
      // The Chief was deleted on the Mac: its computer goes for good, and its slot with it. Only the owner's own key.
      const purged = await sandboxes.ccSandboxPurge()
      await localRegistryOf(env, user).ccLocalComputerRelease(chief)
      return ok({ deleted: purged.deleted })
    }
    if (body.action !== "take_over" && body.action !== "hand_back") return fail({ status: 400, code: "validation.invalid", message: "action must be take_over, hand_back, provision or delete" })
    const r = await sandboxes.ccComputerControl(key, body.action)
    return r.status === 200 ? ok({ control: r.control }) : fail({ status: r.status, code: r.code, message: r.error })
  }
  if (sub === "input") {
    const r = await sandboxes.ccComputerInput(key, body)
    if (r.status === 200) return ok({ done: r.done, control: r.control })
    return fail({ status: r.status, code: r.code, message: r.error, ...(r.state ? { extra: { state: r.state } } : {}) })
  }
  // The Chief's own verb: the same `chief-vm computer` path a Cloud Chief's turn takes, on this Chief's computer only.
  const op = String(body.op ?? "")
  if (!ACT_OPS.has(op)) return fail({ status: 400, code: "validation.invalid", message: `op must be ${[...ACT_OPS].join(", ")}` })
  const status = await sandboxes.ccComputerStatus(key, user)
  if (!status.computer) return fail({ status: 404, code: "not_found", message: "this Chief has no computer: Set Up Computer in its profile" })
  const { op: _op, action: _action, id: _id, ...rest } = body
  const req = op === "start" ? { action: "start", id: status.computer.id } : { ...rest, action: "computer", op, id: status.computer.id }
  // The stub's type of `json: unknown` is never: the object's own answer type.
  const r = (await sandboxes.ccSandboxCall(key, req, [], user)) as { status: number; json: unknown }
  const json = (r.json ?? {}) as Record<string, unknown>
  if (r.status === 200) return ok(json)
  const code = typeof json.code === "string" ? json.code : r.status === 409 ? "computer.asleep" : r.status === 400 ? "validation.invalid" : "computer.unreachable"
  return fail({ status: r.status, code, message: neutral(r.status, typeof json.error === "string" ? json.error : undefined), ...(json.control ? { extra: { control: json.control } } : {}) })
}
