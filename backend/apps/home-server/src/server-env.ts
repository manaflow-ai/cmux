import { randomBytes } from "node:crypto"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { AddressDO } from "../../api/src/address-do.ts"
import { ConversationDO } from "../../api/src/conversation-do.ts"
import { MuxDO } from "../../api/src/mux-do.ts"
import { UserDO } from "../../api/src/user-do.ts"
import { DoRuntime, type ObjectClass } from "./do-runtime/runtime.ts"
import { FixedLengthStream, FsBucket } from "./fs-bucket.ts"
import { RosterDO } from "./roster-do.ts"

// Workers' WebSocket has READY_STATE_* statics (socket-gate.ts reads READY_STATE_OPEN); Bun's has only OPEN and friends.
const ws = globalThis.WebSocket as unknown as Record<string, number>
for (const [k, v] of [["READY_STATE_CONNECTING", 0], ["READY_STATE_OPEN", 1], ["READY_STATE_CLOSING", 2], ["READY_STATE_CLOSED", 3]] as const) if (ws[k] === undefined) Object.defineProperty(ws, k, { value: v })

// Workers' FixedLengthStream (attachment uploads pipe through one); Bun has none.
const g = globalThis as unknown as { FixedLengthStream?: unknown }
g.FixedLengthStream ??= FixedLengthStream

/** Per-server secrets, made once and kept in `<data>/secrets.json` (mode 0600). */
interface ServerSecrets {
  readonly server_id: string
  readonly home_address_key: string
  readonly home_attachment_key: string
}

/** `n` random bytes as lowercase hex. */
const randomHex = (n: number) => [...randomBytes(n)].map((b) => b.toString(16).padStart(2, "0")).join("")

const loadSecrets = (dataDir: string): ServerSecrets => {
  const file = join(dataDir, "secrets.json")
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8")) as ServerSecrets
  const s: ServerSecrets = { server_id: randomHex(10), home_address_key: randomHex(32), home_attachment_key: randomHex(32) }
  writeFileSync(file, JSON.stringify(s, null, 2), { mode: 0o600 })
  return s
}

/** A namespace for an owner class a self-hosted server does not run: every call refuses (not retryable). */
const absentNamespace = (binding: string) => {
  const refuse = () => {
    const e = new Error(`${binding} is not on a self-hosted chat server`) as Error & { retryable: boolean }
    e.retryable = false
    throw e
  }
  const stub = new Proxy({}, { get: (_t, p) => (p === "then" ? undefined : async () => refuse()) })
  return { idFromName: (name: string) => ({ name, toString: () => name }), idFromString: (s: string) => ({ name: s, toString: () => s }), get: () => stub, getByName: () => stub }
}

/** A rate limit binding that always allows (a server's people are known; the per-op limits in the owners still apply). */
const openLimit = { limit: async () => ({ success: true }) }

/** The bindings the chat owners read that a server does not have. */
const ABSENT = ["FEED_DO", "CHIEF_BRAIN_DO", "OPENCODE_BRAIN_DO", "HOST_DO", "PAIRING_DO", "HAND_DO", "CLOUD_DO", "TEAM_VM_DO", "SCHEDULER_DO", "CONNECTION_DO", "ACCOUNT_INDEX_DO", "DOMAIN_DO", "USAGE_METER_DO", "SPEND_GUARD_DO", "FREE_DEVICE_DO", "WIRE_TICKET_DO", "TRAJECTORY_DO"]

/** The self-hosted server's owners and env: the cloud classes on the local runtime. */
export interface ServerRuntime {
  readonly runtime: DoRuntime
  readonly env: Record<string, unknown>
  readonly serverId: string
}

/**
 * Builds the runtime under `dataDir`: ConversationDO, UserDO, MuxDO and AddressDO (the cloud
 * classes, unchanged), the roster as TeamDO for every team id, and an env without PlanetScale,
 * push, invite providers or Chief brains.
 */
export const buildServerRuntime = (dataDir: string, extraEnv: Record<string, unknown> = {}): ServerRuntime => {
  mkdirSync(dataDir, { recursive: true })
  const secrets = loadSecrets(dataDir)
  const env: Record<string, unknown> = {
    ENVIRONMENT: "selfhost",
    WORKER_NAME: "cmux-chat-server",
    PROJECTION_PRIMARY: "none",
    HOME_ADDRESS_KEY: secrets.home_address_key,
    HOME_ATTACHMENT_KEY: secrets.home_attachment_key,
    HOME_ATTACHMENT_KEY_ID: "s1",
    HOME_INVITES_SEND: "off",
    HOME_INVITES_TEXT: "off",
    CHIEF_BRAIN_ENABLED: "0",
    CHIEF_OPENCODE_ENABLED: "0",
    HOME_ATTACHMENT_LIMIT: openLimit,
    // Attachments as files under <data>/blobs (the R2 subset the attachment code uses).
    HOME_ATTACHMENTS: new FsBucket(join(dataDir, "blobs")),
    ...extraEnv
  }
  for (const b of ABSENT) env[b] = absentNamespace(b)
  // Push needs cmux's APNs key, which a server does not have: presence always says "quiet", so no push is tried.
  const feed = { homePushQuiet: async () => true }
  env.FEED_DO = { idFromName: (name: string) => ({ name, toString: () => name }), get: () => feed, getByName: () => feed }
  const runtime = new DoRuntime(dataDir, env)
  runtime.register("CONVERSATION_DO", "ConversationDO", ConversationDO as unknown as ObjectClass)
  runtime.register("USER_DO", "UserDO", UserDO as unknown as ObjectClass)
  runtime.register("MUX_DO", "MuxDO", MuxDO as unknown as ObjectClass)
  runtime.register("ADDRESS_DO", "AddressDO", AddressDO as unknown as ObjectClass)
  runtime.register("ROSTER_DO", "RosterDO", RosterDO as unknown as ObjectClass)
  // Every team id (the caller's personal team, a target's) is this server's one roster.
  env.TEAM_DO = { idFromName: (name: string) => ({ name, toString: () => name }), get: () => runtime.stub("ROSTER_DO", "roster"), getByName: () => runtime.stub("ROSTER_DO", "roster") }
  return { runtime, env, serverId: secrets.server_id }
}
