import { authenticate, withGrantClasses } from "../auth.ts"
import type { Env } from "../env.ts"
import { callerOf } from "../home-attachments.ts"
import type { AutoCaller } from "./model.ts"

/**
 * Who calls an Auto mode route, as hand-offs resolve it (handoffs/routes.ts):
 *
 * - The owner: a signed-in session or a person's install (callerOf): the laptop's daemon, the Mac app, the phone.
 *   Only a laptop's install holds a chat, as the `device:` it first named there (devices.ts).
 * - A machine: the bearer of a VM install bound to one of the owner's Cloud machines. Its holder is
 *   `vm:<that machine>`, and it reaches only chats that machine holds (session-do.ts `admitted`).
 *
 * A chat's object is named by its owner and its id, so a caller reaches their own owner's chats and no other's.
 */
export type Refused = { readonly status: number; readonly code: string; readonly message: string }
export type Who = (AutoCaller & { readonly team: string | null }) | Refused
export const isRefused = (who: Who): who is Refused => "status" in who

/**
 * The install kinds that run a laptop's cmux and so may hold a chat as `device:<id>`: the Mac app, the CLI and its
 * daemon. A phone, the web app and a browser session read a chat and send it messages, and hold none (devices.ts).
 */
const HOLDS = new Set(["mac", "cli", "daemon"])

/** `allow`: who the route is for. `write`: an owner's install needs a grant that covers changes. */
export const callerFor = async (request: Request, env: Env, allow: "owner" | "machine" | "either", write: boolean): Promise<Who> => {
  const bearer = /^Bearer (.+)$/.exec(request.headers.get("authorization") ?? "")?.[1]
  const p = await authenticate(env, bearer)
  if (p?.kind === "install" && p.install_kind === "vm") {
    if (allow === "owner") return { status: 403, code: "auth.forbidden", message: "a Cloud machine cannot do this" }
    const granted = await withGrantClasses(env, p).catch(() => null)
    if (granted === null) return { status: 503, code: "owner.unreachable", message: "the install could not be checked; retry" }
    if (!granted?.user || granted.install_kind !== "vm" || !granted.bound_machine) return { status: 401, code: "auth.unauthenticated", message: "install revoked or not bound to a machine" }
    return { kind: "machine", owner: granted.user, machine: granted.bound_machine, team: granted.team ?? null }
  }
  if (allow === "machine") return { status: 401, code: "auth.unauthenticated", message: "the Auto machine's VM install is required" }
  const caller = await callerOf(request, env, write ? "mutate-shared" : "read")
  if ("status" in caller) return { status: caller.status, code: caller.code, message: caller.message }
  const from = caller.principal
  const install = from.kind === "install" && HOLDS.has(from.install_kind ?? "") ? (from.install ?? null) : null
  return { kind: "owner", owner: caller.user, install, team: from.team ?? null }
}
