import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"

/**
 * The per-user text confirmation level and its device keys (home-messaging.md section 21).
 * Owner UserDO, which delegates to home-core `reduceUserConfirm`. Lowering the level needs a
 * presence-key signature from an owner device (and an App Attest assertion on iOS).
 * `user.presence_key.register` is not public: the Worker commits it after its own checks
 * (POST /v1/presence-key).
 */

export const ConfirmLevel = Schema.Literals(["strict", "destructive-only", "off"]).annotate({ identifier: "ConfirmLevel" })
const confirmErrors = [...mutationErrors, "text_confirm.proof_required", "text_confirm.locked", "forbidden", "invalid_params"]

export const TextConfirmLevelSet = def({
  name: "user.text_confirm.level.set",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "user",
  principals: ["session", "install"],
  params: Schema.Struct({ level: ConfirmLevel }),
  result: Schema.Struct({ level: ConfirmLevel }),
  errors: confirmErrors,
  docs: "Make the text confirmation level safer (applies at once). A riskier level needs lower.challenge and lower.",
  cli: { path: "chief confirm-level set", visible: true },
  mcp: { expose: "never", group: "account" }
})

export const TextConfirmLowerChallenge = def({
  name: "user.text_confirm.lower.challenge",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "user",
  principals: ["install"],
  params: Schema.Struct({ level: ConfirmLevel }),
  result: Schema.Unknown,
  errors: confirmErrors,
  docs: "Owner Mac or iPhone install with an active presence key: returns the exact bytes to sign (2 minutes, one live nonce per install).",
  cli: { path: "chief confirm-level challenge", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const TextConfirmLower = def({
  name: "user.text_confirm.lower",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "user",
  principals: ["install"],
  params: Schema.Struct({
    level: ConfirmLevel,
    nonce: Schema.String.check(Schema.isMaxLength(128)),
    presence_sig: Schema.String.check(Schema.isMaxLength(512)),
    app_attest: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(8192)))
  }),
  result: Schema.Unknown,
  errors: confirmErrors,
  docs: "Lower the level with the signed challenge. Spends the nonce on any attempt; a refused proof commits `lowered: false` with a code.",
  cli: { path: "chief confirm-level lower", visible: false },
  mcp: { expose: "never", group: "account" }
})

export const PresenceKeyRevoke = def({
  name: "user.presence_key.revoke",
  owner: "cloud:UserDO",
  class: "mutation",
  risk: "mutate-own",
  target: "user",
  principals: ["session", "install"],
  params: Schema.Struct({ install: Schema.String.check(Schema.isMaxLength(128)) }),
  result: Schema.Unknown,
  errors: confirmErrors,
  docs: "Make an install's presence key unusable at once (device lost); its nonces are dropped.",
  cli: { path: "chief presence-key revoke", visible: true },
  mcp: { expose: "never", group: "account" }
})

export const TextConfirmGet = def({
  name: "user.text_confirm.get",
  owner: "cloud:UserDO",
  class: "read",
  risk: "read",
  target: "user",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Unknown,
  errors: ["auth.forbidden"],
  docs: "The level in effect, the user's own level, the lock and the presence keys (public parts and usable_from) for Settings.",
  cli: { path: "chief confirm-level get", visible: true },
  mcp: { expose: "never", group: "account" }
})

export const userConfirmOps = [TextConfirmLevelSet, TextConfirmLowerChallenge, TextConfirmLower, PresenceKeyRevoke, TextConfirmGet] as const

const internal = (name: string, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:UserDO",
    class: "mutation",
    risk: "mutate-own",
    target: "user",
    principals: ["system"],
    params: Schema.Unknown,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/** System-only: the Worker (lock, presence-key registration) and chiefs' MuxDO (migrate). home-core checks the exact identity. */
export const userConfirmInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("user.text_confirm.lock", "Internal: a team policy or MDM minimum level (one slot per source)."),
  internal("user.text_confirm.migrate", "Internal: a chief's former level, once, from system:mux:<agent>."),
  internal("user.presence_key.register", "Internal: the Worker registers a presence key after its signature or App Attest check.")
]
