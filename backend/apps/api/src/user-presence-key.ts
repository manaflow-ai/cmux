import type { Principal } from "@cmux/ownership"
import { verifyInstallSignature } from "./auth.ts"
import { verifyAttestation, type AttestedKey } from "./app-attest.ts"
import { installActive, jwkThumbprint, type UserState } from "./domains/user.ts"
import type { Env } from "./env.ts"

/** POST /v1/presence-key body. */
export interface PresenceKeyBody {
  readonly platform?: unknown
  readonly jwk?: unknown
  readonly signature?: unknown
  readonly attestation?: unknown
  readonly key_id?: unknown
}

export type PresenceKeyCheck =
  | { readonly error: { code: string; message: string } }
  | { readonly params: Record<string, unknown>; readonly key: string }

/**
 * The UserDO's checks for POST /v1/presence-key (home-messaging.md section 21): the caller is
 * an active owner device install registering its own key; both platforms have the install key
 * sign `cmux-presence-key-v1\n<environment>\n<user>\n<install>\n<thumbprint>`; iOS also sends an
 * App Attest attestation whose client data is the key's thumbprint. Answers the params and
 * idempotency key of `user.presence_key.register`. `state` binds the user only after the
 * principal check, so a foreign caller creates no storage.
 */
export const checkPresenceKey = async (env: Env, entity: string, principal: Principal, state: () => UserState, body: PresenceKeyBody): Promise<PresenceKeyCheck> => {
  const refuse = (code: string, message: string) => ({ error: { code, message } })
  if (principal.kind !== "install" || principal.agent || principal.user !== entity || !principal.install) return refuse("auth.forbidden", "an owner device install registers its own key")
  const current = state()
  const inst = current.installs[principal.install]
  if (!installActive(current, principal) || !inst) return refuse("auth.forbidden", "install revoked or unknown")
  if ((body.platform !== "mac" && body.platform !== "ios") || inst.kind !== body.platform) return refuse("validation.invalid", "platform must be this install's kind (mac or ios)")
  const jwk = body.jwk as { kty?: string; crv?: string; x?: string; y?: string } | undefined
  if (!jwk || jwk.kty !== "EC" || jwk.crv !== "P-256" || typeof jwk.x !== "string" || typeof jwk.y !== "string") return refuse("validation.invalid", "jwk must be a P-256 public key")
  const thumbprint = jwkThumbprint({ kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y })
  let appAttest: AttestedKey | undefined
  // Both platforms: the install key signs the registration, so a stolen bearer token alone cannot replace the key.
  const message = `cmux-presence-key-v1\n${env.ENVIRONMENT}\n${entity}\n${inst.id}\n${thumbprint}`
  if (typeof body.signature !== "string" || !(await verifyInstallSignature(inst.public_jwk, message, body.signature))) return refuse("auth.forbidden", "the install key did not sign this registration")
  if (body.platform === "ios") {
    if (!env.IOS_APP_ID) return refuse("presence_key.not_configured", "App Attest is not configured on this deployment")
    if (typeof body.attestation !== "string" || typeof body.key_id !== "string") return refuse("validation.invalid", "attestation and key_id are required on iOS")
    const r = verifyAttestation({
      attestation: body.attestation,
      keyId: body.key_id,
      clientData: new TextEncoder().encode(thumbprint),
      appId: env.IOS_APP_ID,
      allowDevelopment: env.IOS_APP_ATTEST_DEVELOPMENT === "true",
      now: Date.now()
    })
    if (!r.ok) return refuse("auth.forbidden", `attestation refused (${r.reason})`)
    appAttest = r.key
  }
  const params = { install: inst.id, jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, platform: body.platform, ...(appAttest ? { app_attest: appAttest } : {}) }
  return { params, key: `presence-key:${inst.id}:${thumbprint}` }
}
