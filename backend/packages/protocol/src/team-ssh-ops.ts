import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { InstallId, TeamId, UserId } from "./schemas.ts"

/**
 * The team SSH certificate authority (plans/cmux-next/team-vm-plan.md S3, spec/team-vm.md "SSH
 * access"). TeamDO owns the CA key (sealed under a Worker key, never in an op, event or log), the
 * issued-certificate log and the revocation list (KRL). The team VM's sshd trusts only this CA,
 * maps certificate principals to Linux users, and loads the KRL that `team_vm.ssh_ca` returns.
 */

export const SshCertClass = Schema.Literals(["human", "agent"]).annotate({
  identifier: "SshCertClass",
  description:
    "`human`: a full shell as the person's Linux user. `agent`: the person's `<name>-agents` Linux user, limited by the certificate's force-command to `cmux team …` commands (decision D28)."
})

/** The force-command of `agent` certificates. The team VM's image provides it (slice S5): it runs only `cmux team …` from SSH_ORIGINAL_COMMAND. */
export const SSH_AGENT_FORCE_COMMAND = "cmux team restricted-shell"
/** Certificate extension that lists the team VMs this certificate reaches (the SSH gate reads it, slice S12). */
export const SSH_TEAMS_EXTENSION = "cmux-teams@cmux.dev"

export const SshPresenceProof = Schema.Struct({
  install: InstallId,
  nonce: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128)),
  /** ES256 over the challenge's `message` bytes, raw r||s (64 bytes), base64url. */
  signature: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(512)),
  /** iOS: an App Attest assertion over the same bytes, base64url. */
  app_attest: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(8192)))
}).annotate({ identifier: "SshPresenceProof" })

export const TeamVmSshCertChallenge = def({
  name: "team_vm.ssh_cert.challenge",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "execute",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    public_key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(1000)),
    validity_minutes: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 15, maximum: 60 }))),
    /** The person's device (Mac or iPhone install with a presence key past its 24 h cooldown) that approves. */
    presence_install: InstallId,
    /** The idempotency key of the `team_vm.ssh_cert` call this approval authorizes (one certificate). */
    request: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(256))
  }),
  result: Schema.Struct({
    /** The fields the device shows and signs: team, Linux user, key fingerprint, validity, nonce, expiry. */
    sign: Schema.Unknown,
    /** The exact bytes to sign (base64url); never re-encode `sign`. */
    message: Schema.String,
    /** Milliseconds since the epoch; 2 minutes after the challenge. */
    expires_at: Schema.Int
  }),
  errors: [...mutationErrors, "team_vm.ssh_ca_not_configured", "team_vm.ssh_key_invalid", "team_vm.ssh_class_refused", "team_vm.ssh_presence_refused", "team_vm.ssh_rate_limited", "owner.unreachable"],
  docs: "Start a full-shell SSH certificate request: returns a single-use presence challenge for one of your devices. Approve it there (Face ID, Touch ID or passcode), then call team_vm.ssh_cert with class human, the proof and the same request key.",
  cli: { path: "team ssh challenge", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamVmSshCert = def({
  name: "team_vm.ssh_cert",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "execute",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    /** The caller's public key as one authorized_keys line: `ssh-ed25519 …` or `ecdsa-sha2-nistp256 …`. */
    public_key: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(1000)),
    /** Default 30. */
    validity_minutes: Schema.optionalKey(Schema.Int.check(Schema.isBetween({ minimum: 15, maximum: 60 }))),
    /** Default: `human` for a person's session (then `presence` is required: `team_vm.ssh_presence_required` without it), `agent` for an install token (D28). */
    class: Schema.optionalKey(SshCertClass),
    /**
     * Required for `human` (decision SSH-1): the presence proof from `team_vm.ssh_cert.challenge`, signed after
     * Face ID, Touch ID or the device passcode by the presence key of `install` (one of the person's own devices).
     * The challenge's `request` must equal this call's idempotency key.
     */
    presence: Schema.optionalKey(SshPresenceProof)
  }),
  result: Schema.Struct({
    /** The OpenSSH certificate (`*-cert.pub` line). */
    certificate: Schema.String,
    serial: Schema.Int,
    /** `<cmux principal>/<grant>/<install>/<nonce>`; the team VM logs it for every login. */
    key_id: Schema.String,
    /** The Linux users the certificate may log in as. */
    principals: Schema.Array(Schema.String),
    class: SshCertClass,
    /** Milliseconds since the epoch. */
    valid_after: Schema.Int,
    valid_before: Schema.Int,
    ca_generation: Schema.Int,
    /** The CA public key (authorized_keys line) that signed the certificate. */
    ca_public_key: Schema.String
  }),
  errors: [
    ...mutationErrors,
    "team_vm.ssh_ca_not_configured",
    "team_vm.ssh_key_invalid",
    "team_vm.ssh_class_refused",
    "team_vm.ssh_presence_required",
    "team_vm.ssh_presence_refused",
    "team_vm.ssh_rate_limited",
    "team_vm.tainted",
    "owner.unreachable"
  ],
  docs: "Sign a short-lived SSH user certificate (15 to 60 minutes) for the team VM. The certificate names the caller's Linux user; `agent` certificates run only `cmux team …` commands; a `human` (full shell) certificate needs a person's session and a fresh presence proof. While the team VM is tainted by a member removal (team_vm.status `taint`, not accepted) only owners and admins get one (`team_vm.tainted`). Replaying the same idempotency key returns the same certificate, also after a crash.",
  cli: { path: "team ssh cert", visible: true },
  mcp: { expose: "opt_in", group: "team" }
})

export const TeamVmSshCertRevoke = def({
  name: "team_vm.ssh_cert.revoke",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({
    /** Exactly one selector. */
    serial: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(1))),
    user: Schema.optionalKey(UserId),
    install: Schema.optionalKey(InstallId),
    reason: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(200)))
  }),
  result: Schema.Struct({ revoked: Schema.Array(Schema.Int), krl_version: Schema.Int }),
  errors: [...mutationErrors, "team_vm.ssh_ca_not_configured", "team_vm.ssh_revocations_full", "owner.unreachable"],
  docs: "Revoke unexpired team VM SSH certificates by serial, user or install; the revocation list (KRL) lists them at once. Members revoke their own certificates; owners and admins revoke anyone's.",
  cli: { path: "team ssh revoke", visible: true },
  mcp: { expose: "opt_in", group: "team" }
})

export const TeamVmSshCaRotate = def({
  name: "team_vm.ssh_ca.rotate",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    /** True when the old key may be known to someone: the old CA stops being trusted at once and is listed in the KRL. */
    compromised: Schema.optionalKey(Schema.Boolean)
  }),
  result: Schema.Struct({ generation: Schema.Int, ca_public_key: Schema.String, previous_trusted_until: Schema.NullOr(Schema.Int) }),
  errors: [...mutationErrors, "team_vm.ssh_ca_not_configured", "owner.unreachable"],
  docs: "Replace the team SSH CA key (owners and admins, in a person's session). Without `compromised`, certificates from the old key stay valid until they expire (at most 60 minutes).",
  cli: { path: "team ssh rotate-ca", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const TeamVmSshCaRead = def({
  name: "team_vm.ssh_ca",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({
    team: TeamId,
    /** 0 before the first certificate. */
    generation: Schema.Int,
    /** sshd `TrustedUserCAKeys` lines: the current CA and, during a rotation, the previous one. */
    trusted_ca_keys: Schema.Array(Schema.String),
    /** sshd `RevokedKeys`: the OpenSSH KRL, base64. */
    krl: Schema.String,
    krl_version: Schema.Int
  }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The team SSH CA public keys and the current revocation list (KRL), for the team VM's sshd.",
  cli: { path: "team ssh ca", visible: true },
  mcp: { expose: "default", group: "team" }
})

export const teamSshOps = [TeamVmSshCertChallenge, TeamVmSshCert, TeamVmSshCertRevoke, TeamVmSshCaRotate, TeamVmSshCaRead] as const satisfies readonly CloudOpDef[]

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:TeamDO",
    class: "mutation",
    risk: "mutate-shared",
    target: "team",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

/** Ops only TeamDO submits, after its own crypto or storage step. Not exported to the catalog. */
export const teamSshInternalOps: ReadonlyArray<CloudOpDef> = [
  internal(
    "team_vm.ssh_ca_installed",
    Schema.Struct({ generation: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)), public_key: Schema.String, compromised: Schema.Boolean, by: Schema.String }),
    "Internal: a new CA key was sealed and stored; it signs from now on."
  ),
  internal(
    "team_vm.ssh_certs_revoked",
    Schema.Struct({
      serials: Schema.Array(Schema.Struct({ serial: Schema.Int, valid_before: Schema.Int, generation: Schema.Int })),
      by: Schema.String,
      /** An owner or admin revoked (may pass the members' bound on live revocations). */
      admin: Schema.optionalKey(Schema.Boolean),
      /** UserDO revoked the install: never refused for a full list. */
      system: Schema.optionalKey(Schema.Boolean),
      reason: Schema.String
    }),
    "Internal: certificates found in the issued log were revoked."
  ),
  internal("team_vm.ssh_account_allocated", Schema.Struct({ user: UserId }), "Internal: a member's Linux account name and UID block (never reused)."),
  internal(
    "team_vm.taint_audit",
    Schema.Struct({
      /** cert_issued_while_tainted, taint_accepted, rebuild, retired_deleted. */
      action: Schema.Literals(["cert_issued_while_tainted", "taint_accepted", "rebuild", "retired_deleted"]),
      by: Schema.String,
      epoch: Schema.Int,
      /** The removed members whose certificates tainted the VM. */
      tainted_by: Schema.Array(Schema.String),
      serial: Schema.optionalKey(Schema.Int),
      vm: Schema.optionalKey(Schema.String)
    }),
    "Internal: an owner or admin acted on a tainted team VM (cx-q4f3); audit only."
  )
]
