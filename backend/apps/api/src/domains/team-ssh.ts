import type { ReduceContext } from "@cmux/ownership"
import { buildKrl, toBase64 } from "../team-ssh-wire.ts"
import { reject } from "./common.ts"
import { appendAudit, type AuditState } from "./team-audit.ts"

/**
 * TeamDO's SSH CA records (plans/cmux-next/team-vm-plan.md S3). The private key is not here:
 * it is sealed in TeamDO's `ssh_ca_keys` side table (team-ssh-ca.ts). This state holds what
 * everyone may see: the CA public keys, the revoked serials until they expire, the revoked CA
 * keys, and each member's Linux account (name and UID block, never reused).
 */
export interface SshCaKey {
  readonly generation: number
  /** authorized_keys line `ssh-ed25519 … cmux-team-ca-<generation>`. */
  readonly public_key: string
  readonly created_at: number
}

export interface VmAccount {
  readonly name: string
  /** First UID of the member's block: +0 the person, +1 their mux, +2 their ordinary agents. */
  readonly uid: number
}

export interface TeamSshState {
  readonly ssh_ca?: SshCaKey & { readonly previous?: SshCaKey & { readonly trusted_until: number } }
  /** Revoked serials until their certificate expires: serial -> expiry and signing CA generation. */
  readonly ssh_revoked?: Readonly<Record<string, { readonly valid_before: number; readonly generation: number }>>
  /** CA public keys revoked by a compromised rotation (newest last). */
  readonly ssh_revoked_ca_keys?: ReadonlyArray<string>
  readonly ssh_krl?: { readonly version: number; readonly at: number }
  readonly vm_accounts?: Readonly<Record<string, VmAccount>>
  readonly vm_next_uid?: number
}

/** Longest certificate validity; a rotated (not compromised) CA stays trusted this long. */
export const MAX_CERT_MS = 60 * 60_000
export const FIRST_UID = 20_000
export const UID_BLOCK = 4
/** Bound on live revocations (each expires within an hour); a full list refuses, never drops. */
export const MAX_REVOKED = 10_000
const MAX_REVOKED_CA_KEYS = 16

/** System users and names the team VM's image or reconciler use (no member may take them). */
const RESERVED = new Set(
  "root daemon bin sys sync games man lp mail news uucp proxy backup list irc gnats nobody sshd systemd messagebus syslog ubuntu admin administrator gate cmux team teams app apps run runs mux muxes agent agents postgres www tss uuidd lxd dnsmasq landscape pollinate fwupd polkitd usbmux tcpdump operator halt shutdown ftp guest user users staff wheel sudo adm audit".split(
    " "
  )
)

/** Linux name base from a display name: first ASCII word, lowercase letters and digits, starts with a letter. */
export const linuxNameBase = (displayName: string): string => {
  const word =
    displayName
      .normalize("NFKD")
      .toLowerCase()
      .replace(/[^\x00-\x7f]/g, "")
      .split(/[^a-z0-9]+/)
      .find((w) => w.length > 0) ?? ""
  const base = /^[a-z]/.test(word) ? word : `u${word}`
  return base.slice(0, 20)
}

/** A unique, unreserved name (suffix 2, 3, … on collision). At most 24 characters, so `<name>-agents` fits 32. */
export const allocateLinuxName = (displayName: string, taken: ReadonlySet<string>): string => {
  const base = linuxNameBase(displayName)
  if (!RESERVED.has(base) && !taken.has(base)) return base
  for (let n = 2; ; n++) {
    const name = `${base}${n}`
    if (!RESERVED.has(name) && !taken.has(name)) return name
  }
}

export const linuxUserFor = (account: VmAccount, cls: "human" | "agent"): string => (cls === "human" ? account.name : `${account.name}-agents`)

const blobOfLine = (line: string): Uint8Array => Uint8Array.from(atob(line.split(" ")[1] ?? ""), (c) => c.charCodeAt(0))

/** CA keys sshd should trust now: the current one and a rotated one until its grace ends. */
export const trustedCaKeys = (s: TeamSshState, now: number): Array<string> => {
  if (!s.ssh_ca) return []
  const prev = s.ssh_ca.previous
  return prev && prev.trusted_until > now ? [s.ssh_ca.public_key, prev.public_key] : [s.ssh_ca.public_key]
}

/** The KRL for the current state (deterministic: same state, same bytes). */
export const krlFor = (s: TeamSshState, now: number): Uint8Array => {
  const cas = [s.ssh_ca, s.ssh_ca?.previous].filter((c): c is SshCaKey => Boolean(c))
  const live = Object.entries(s.ssh_revoked ?? {}).filter(([, r]) => r.valid_before > now)
  return buildKrl({
    version: s.ssh_krl?.version ?? 0,
    generatedAt: Math.floor((s.ssh_krl?.at ?? 0) / 1000),
    comment: "cmux team",
    serials: cas.map((ca) => ({ caBlob: blobOfLine(ca.public_key), serials: live.filter(([, r]) => r.generation === ca.generation).map(([serial]) => Number(serial)) })),
    keys: (s.ssh_revoked_ca_keys ?? []).map(blobOfLine)
  })
}

export const sshCaView = (team: string, s: TeamSshState, now: number) => ({
  team,
  generation: s.ssh_ca?.generation ?? 0,
  trusted_ca_keys: trustedCaKeys(s, now),
  krl: toBase64(krlFor(s, now)),
  krl_version: s.ssh_krl?.version ?? 0
})

type Out<S> = { ok: true; state: S; value: unknown; changed?: boolean; outbox?: Array<{ kind: string; entity: string; payload: unknown }> } | ReturnType<typeof reject>

const audited = <S extends TeamSshState & AuditState>(state: S, team: string, ctx: ReduceContext, op: string, value: unknown, summary: string, detail: unknown): Out<S> => {
  const a = appendAudit(state, team, ctx, op, summary, detail)
  return { ok: true, state: a.state, value, outbox: [a.outbox] }
}

export const reduceCaInstalled = <S extends TeamSshState & AuditState>(state: S, team: string, params: unknown, ctx: ReduceContext): Out<S> => {
  const p = params as { generation: number; public_key: string; compromised: boolean; by: string }
  const cur = state.ssh_ca
  if (cur && p.generation <= cur.generation) return { ok: true, state, value: { generation: cur.generation }, changed: false }
  if (p.generation !== (cur?.generation ?? 0) + 1) return reject("revision.conflict", "the CA generation moved; retry")
  if (!/^ssh-ed25519 [A-Za-z0-9+/]+={0,2} /.test(p.public_key)) return reject("validation.invalid", "CA public key must be an ssh-ed25519 line")
  const previous = cur ? { generation: cur.generation, public_key: cur.public_key, created_at: cur.created_at, trusted_until: p.compromised ? ctx.now : ctx.now + MAX_CERT_MS } : undefined
  const revokedCa = cur && p.compromised ? [...(state.ssh_revoked_ca_keys ?? []), cur.public_key].slice(-MAX_REVOKED_CA_KEYS) : state.ssh_revoked_ca_keys
  const next: S = {
    ...state,
    ssh_ca: { generation: p.generation, public_key: p.public_key, created_at: ctx.now, ...(previous ? { previous } : {}) },
    ...(revokedCa ? { ssh_revoked_ca_keys: revokedCa } : {}),
    ssh_krl: { version: (state.ssh_krl?.version ?? 0) + 1, at: ctx.now }
  }
  const summary = !cur ? "SSH CA created" : p.compromised ? `SSH CA rotated to generation ${p.generation} (old key revoked)` : `SSH CA rotated to generation ${p.generation}`
  return audited(next, team, ctx, "team_vm.ssh_ca_installed", { generation: p.generation, previous_trusted_until: previous?.trusted_until ?? null }, summary, {
    generation: p.generation,
    public_key: p.public_key,
    compromised: p.compromised,
    by: p.by
  })
}

export const reduceCertsRevoked = <S extends TeamSshState & AuditState>(state: S, team: string, params: unknown, ctx: ReduceContext): Out<S> => {
  const p = params as { serials: ReadonlyArray<{ serial: number; valid_before: number; generation: number }>; by: string; reason: string }
  const kept = Object.fromEntries(Object.entries(state.ssh_revoked ?? {}).filter(([, r]) => r.valid_before > ctx.now))
  const added = p.serials.filter((s) => s.valid_before > ctx.now && !kept[String(s.serial)])
  if (added.length === 0) return { ok: true, state, value: { revoked: [], krl_version: state.ssh_krl?.version ?? 0 }, changed: false }
  if (Object.keys(kept).length + added.length > MAX_REVOKED) return reject("team_vm.ssh_revocations_full", "too many live revocations; rotate the CA with compromised = true instead")
  for (const s of added) kept[String(s.serial)] = { valid_before: s.valid_before, generation: s.generation }
  const version = (state.ssh_krl?.version ?? 0) + 1
  const next: S = { ...state, ssh_revoked: kept, ssh_krl: { version, at: ctx.now } }
  const serials = added.map((s) => s.serial)
  return audited(next, team, ctx, "team_vm.ssh_certs_revoked", { revoked: serials, krl_version: version }, `revoked ${serials.length} SSH certificate(s)`, { serials, by: p.by, reason: p.reason })
}

export const reduceAccountAllocated = <S extends TeamSshState & { readonly members: Readonly<Record<string, { readonly display_name: string }>> }>(state: S, params: unknown): Out<S> => {
  const user = (params as { user: string }).user
  const member = state.members[user]
  if (!member) return reject("auth.forbidden", "not a member of this team")
  const existing = state.vm_accounts?.[user]
  if (existing) return { ok: true, state, value: existing, changed: false }
  const taken = new Set(Object.values(state.vm_accounts ?? {}).map((a) => a.name))
  const account: VmAccount = { name: allocateLinuxName(member.display_name, taken), uid: state.vm_next_uid ?? FIRST_UID }
  return { ok: true, state: { ...state, vm_accounts: { ...state.vm_accounts, [user]: account }, vm_next_uid: account.uid + UID_BLOCK }, value: account }
}
