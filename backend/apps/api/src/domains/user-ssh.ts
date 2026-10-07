import type { Domain, Principal, ReduceResult } from "@cmux/ownership"
import { reject } from "./common.ts"

/**
 * `ssh:<user>`: the user's synced SSH host records (lane C9; b1-control-do.md section 8;
 * schemas/mobile-rpc/families/ssh.schema.json). A UserDO secondary stream. Records name the public
 * key fingerprint a device holds; a private key, password or passphrase never reaches the backend,
 * so params with such a field are refused outright.
 */

export interface SshHost {
  readonly id: string
  readonly name: string
  readonly hostname: string
  readonly port: number
  readonly user: string
  readonly jump?: string
  readonly key?: string
}

export interface KnownHostKey {
  readonly key_type: string
  readonly key: string
  readonly fingerprint: string
}

export interface SshState {
  readonly hosts: Readonly<Record<string, SshHost>>
  readonly known: Readonly<Record<string, ReadonlyArray<KnownHostKey>>>
}

export const MAX_SSH_HOSTS = 500
export const MAX_KNOWN_KEYS = 16

const SSH_ID = /^ssh_[A-Za-z0-9]{2,64}$/
const FINGERPRINT = /^SHA256:[A-Za-z0-9+/]{43}$/
const KEY_BLOB = /^[A-Za-z0-9+/=]{16,8192}$/
const KEY_TYPES = new Set(["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "rsa-sha2-256", "rsa-sha2-512"])
const SECRET_FIELDS = /(private|secret|password|passphrase)/i
const HOST_FIELDS = new Set(["id", "name", "hostname", "port", "user", "jump", "key"])

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)

/** True when any key at any depth names a secret. */
const carriesSecret = (v: unknown, depth = 0): boolean =>
  depth < 4 && isObj(v) ? Object.entries(v).some(([k, x]) => SECRET_FIELDS.test(k) || carriesSecret(x, depth + 1)) : false

const hostOf = (v: unknown): SshHost | string => {
  if (!isObj(v)) return "host must be an object"
  if (!Object.keys(v).every((k) => HOST_FIELDS.has(k))) return "unknown host field"
  const { id, name, hostname, port, user, jump, key } = v
  if (typeof id !== "string" || !SSH_ID.test(id)) return "host.id must be an ssh_ id"
  if (typeof name !== "string" || name.length < 1 || name.length > 200) return "host.name must be 1 to 200 characters"
  if (typeof hostname !== "string" || hostname.length < 1 || hostname.length > 253 || /\s/.test(hostname)) return "host.hostname must be 1 to 253 characters"
  if (!Number.isInteger(port) || (port as number) < 1 || (port as number) > 65535) return "host.port must be 1 to 65535"
  if (typeof user !== "string" || user.length < 1 || user.length > 64) return "host.user must be 1 to 64 characters"
  if (jump !== undefined && (typeof jump !== "string" || !SSH_ID.test(jump) || jump === id)) return "host.jump must be another ssh_ id"
  if (key !== undefined && (typeof key !== "string" || !FINGERPRINT.test(key))) return "host.key must be a SHA256 fingerprint"
  return { id, name, hostname, port: port as number, user, ...(jump ? { jump: jump as string } : {}), ...(key ? { key: key as string } : {}) }
}

const ok = (state: SshState, value: unknown, changed = true): ReduceResult<SshState> => ({ ok: true, state, value, changed })

export const sshDomain: Domain<SshState> = {
  initial: () => ({ hosts: {}, known: {} }),
  reduce: (state, op, params) => {
    if (carriesSecret(params)) return reject("validation.invalid", "ssh records never carry private keys, passwords or passphrases")
    const p = isObj(params) ? params : {}
    switch (op) {
      case "ssh.host.upsert": {
        const host = hostOf(p.host)
        if (typeof host === "string") return reject("validation.invalid", host)
        if (!state.hosts[host.id] && Object.keys(state.hosts).length >= MAX_SSH_HOSTS) return reject("validation.invalid", `at most ${MAX_SSH_HOSTS} ssh hosts`)
        if (host.jump && !state.hosts[host.jump]) return reject("ssh.host_not_found", "jump host not found")
        if (JSON.stringify(state.hosts[host.id]) === JSON.stringify(host)) return ok(state, { id: host.id }, false)
        return ok({ ...state, hosts: { ...state.hosts, [host.id]: host } }, { id: host.id })
      }
      case "ssh.host.remove": {
        const id = p.id
        if (typeof id !== "string" || !SSH_ID.test(id)) return reject("validation.invalid", "id must be an ssh_ id")
        if (!state.hosts[id]) return reject("ssh.host_not_found", "ssh host not found")
        const { [id]: _gone, ...hosts } = state.hosts
        const { [id]: _keys, ...known } = state.known
        // A host used as another's jump host leaves that link dangling: clear it in the same commit.
        const fixed = Object.fromEntries(Object.entries(hosts).map(([k, h]) => [k, h.jump === id ? (({ jump: _j, ...rest }) => rest)(h) : h]))
        return ok({ hosts: fixed, known }, { id })
      }
      case "ssh.known_host.add": {
        const { id, key_type, key, fingerprint } = p
        if (typeof id !== "string" || !SSH_ID.test(id)) return reject("validation.invalid", "id must be an ssh_ id")
        if (typeof key_type !== "string" || !KEY_TYPES.has(key_type)) return reject("validation.invalid", "unsupported key_type")
        if (typeof key !== "string" || !KEY_BLOB.test(key)) return reject("validation.invalid", "key must be base64")
        if (typeof fingerprint !== "string" || !FINGERPRINT.test(fingerprint)) return reject("validation.invalid", "fingerprint must be SHA256:<base64>")
        if (!state.hosts[id]) return reject("ssh.host_not_found", "ssh host not found")
        const list = state.known[id] ?? []
        if (list.some((k) => k.fingerprint === fingerprint && k.key_type === key_type)) return ok(state, { id, fingerprint }, false)
        if (list.length >= MAX_KNOWN_KEYS) return reject("validation.invalid", `at most ${MAX_KNOWN_KEYS} known keys per host`)
        return ok({ ...state, known: { ...state.known, [id]: [...list, { key_type, key, fingerprint }] } }, { id, fingerprint })
      }
      default:
        return reject("validation.invalid", `unknown op ${op} for ssh`)
    }
  },
  authorize: (_state, _op, _params, principal: Principal) =>
    principal.kind === "session" || principal.kind === "install" ? undefined : { code: "auth.forbidden", message: "ssh records belong to the user" }
}
