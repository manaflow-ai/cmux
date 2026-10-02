import type { ReduceContext, ReduceResult } from "@cmux/ownership"
import { PushTargetRegister, PushTargetRemove, type PushTarget } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"

/** The slice of UserDO state that holds device push targets (absent in objects created before it). */
export interface PushTargetsState {
  readonly push_targets?: Readonly<Record<string, PushTarget>>
}

/** At most this many push targets per user; the oldest goes first. */
export const MAX_PUSH_TARGETS = 20

/**
 * push.target.register / push.target.remove (UserDO): an install registers
 * its own APNs token; one token per install (a new token replaces the old);
 * the user's session or the registering install removes one.
 */
export const reducePushTarget = <S extends PushTargetsState>(state: S, op: string, params: unknown, ctx: ReduceContext): ReduceResult<S> => {
  const targets = state.push_targets ?? {}
  const p = ctx.principal
  if (op === "push.target.register") {
    const d = decodeParams<typeof PushTargetRegister.params.Type>(PushTargetRegister, params)
    if (!d.ok) return d
    if (p.kind !== "install" || !p.install) return reject("auth.forbidden", "only a device install registers its push token")
    const v = d.value
    const prior = targets[v.token]
    if (prior && prior.install !== p.install) return reject("auth.forbidden", "this token belongs to another install")
    const target: PushTarget = { token: v.token, topic: v.topic, environment: v.environment, install: p.install, device_name: v.device_name ?? "", registered_at: prior?.registered_at ?? ctx.now }
    if (prior && JSON.stringify(prior) === JSON.stringify(target)) return { ok: true, state, value: target, changed: false }
    const kept = Object.values(targets).filter((t) => t.install !== p.install).sort((a, b) => a.registered_at - b.registered_at)
    const room = kept.slice(Math.max(0, kept.length - (MAX_PUSH_TARGETS - 1)))
    const next = Object.fromEntries([...room, target].map((t) => [t.token, t]))
    return { ok: true, state: { ...state, push_targets: next }, value: target }
  }
  if (op === "push.target.remove" || op === "push.target.drop") {
    const d = decodeParams<typeof PushTargetRemove.params.Type>(PushTargetRemove, { token: (params as { token?: unknown } | null)?.token })
    if (!d.ok) return d
    if (op === "push.target.drop" && p.kind !== "system") return reject("auth.forbidden", "push.target.drop is internal")
    const prior = targets[d.value.token]
    if (!prior) return { ok: true, state, value: { token: d.value.token, removed: false }, changed: false }
    if (p.kind !== "session" && p.kind !== "system" && p.install !== prior.install) return reject("auth.forbidden", "an install removes only its own token")
    const { [d.value.token]: _, ...rest } = targets
    return { ok: true, state: { ...state, push_targets: rest }, value: { token: d.value.token, removed: true } }
  }
  return reject("validation.invalid", `unknown op ${op}`)
}
