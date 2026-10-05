/**
 * Writes backend/catalog/cloud-vectors.json: cmux.wire/1 request and response
 * vectors for the cmux-next Cloud ops (cloud-machine-ops.ts;
 * plans/cmux-next/cloud-client-contract.md 1.3, 1.4 and 1.7). The client
 * tests (first-party-apps/cloud/server) and the backend tests read the file
 * by path. Synthetic data only.
 *
 *   bun scripts/export-cloud-vectors.ts          write
 *   bun scripts/export-cloud-vectors.ts --check  fail when the checked-in file differs
 */
import { readFileSync, writeFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { cloudEntryPlan } from "../src/cloud-plans.ts"
import { overlayAddress } from "../src/overlay.ts"
import { backendOnlyCases } from "./cloud-vectors-backend-only.ts"

/** The plan the refusals and the checkout name, from the plan catalog (never a literal). */
const PLAN_ID = cloudEntryPlan()

type Json = null | boolean | number | string | Array<Json> | { [k: string]: Json }
type Obj = { [k: string]: Json }

const TEAM = "team_t0000000000000000001"
const USER = "user_u0000000000000000001"
const INSTALL = "inst_i0000000000000000001"
const AGENT = "agent_chief01"
const STREAM = `cloud:${TEAM}`

const pad = (n: number) => String(n).padStart(19, "0")
const vm = (n: number) => `vm_m${pad(n)}`
const snap = (n: number) => `snap_s${pad(n)}`
const host = (n: number) => `host_h${pad(n)}`

const IMAGE = { id: "img_i0000000000000000001", daemon_version: "0.40.0" }

const machine = (
  n: number,
  name: string,
  status: string,
  rev: number,
  { bound = true, size = [2, 4096, 16384], classic = false, idle = 1800 }: { bound?: boolean; size?: Array<number>; classic?: boolean; idle?: number } = {}
): Obj => ({
  id: vm(n),
  team: TEAM,
  creator: USER,
  name,
  size: { cpu: size[0]!, memory_mb: size[1]!, disk_mb: size[2]! },
  status,
  image: IMAGE,
  host: bound ? host(n) : null,
  classic,
  created_at: 1790000000000 + n * 1000,
  last_active_at: 1790000600000 + n * 1000,
  idle_policy: { idle_seconds: idle },
  error: null,
  revision: String(rev)
})

const snapshot = (n: number, m: number, name: string, rev: number, status = "ready"): Obj => ({
  id: snap(n),
  machine: vm(m),
  name,
  size_mb: 2048,
  status,
  created_at: 1790001000000 + n * 1000,
  revision: String(rev)
})

const M1 = machine(1, "build box", "running", 7)
const M2 = machine(2, "docs box", "paused", 4)
const M3 = machine(3, "scratch", "running", 5)
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }

let txN = 0
const tx = () => `tx_${String(++txN).padStart(4, "0")}`
let seqN = 100
const seq = () => ++seqN

const readOk = (op: string, value: Json, revision = "41"): Obj => ({
  http: { path: "/v1/read", status: 200 },
  body: { op, value, stream: STREAM, revision }
})
const readErr = (status: number, tag: string, code: string, message: string): Obj => ({
  http: { path: "/v1/read", status },
  body: { _tag: tag, code, message }
})
const opOk = (op: string, key: string, value: Json, revision: string, replayed = false): Obj => ({
  http: { path: "/v1/ops", status: 200 },
  body: { ok: true, op, value, transaction: tx(), idempotency_key: key, revision, replayed, stream: STREAM, sequence: seq() }
})
const opErr = (op: string, key: string, code: string, message: string, retryable = false, details?: Json): Obj => ({
  http: { path: "/v1/ops", status: 200 },
  body: {
    ok: false,
    op,
    error: { code, message, retryable, ...(details === undefined ? {} : { details }) },
    transaction: "",
    idempotency_key: key,
    replayed: false,
    stream: STREAM,
    sequence: 0
  }
})
const replayPair = (op: string, key: string, value: Json, revision: string): Array<Obj> => {
  const first = opOk(op, key, value, revision)
  const again = JSON.parse(JSON.stringify(first)) as { body: Obj }
  again.body.replayed = true
  return [first, again as unknown as Obj]
}

const INSTALL_P = { kind: "install" }
const AGENT_P = { kind: "install", agent: AGENT }
/** A signed-in person (session). Money and destructive ops need one (decision: never the default install grants). */
const SESSION_P = { kind: "session" }
/** Ops that cost money or destroy data: a user principal, or later an install with a fresh origin.confirmation (ORIGIN). */
const PERSON_OPS = new Set(["cloud.machine.create", "cloud.machine.delete", "cloud.machine.resize", "cloud.machine.upgrade", "cloud.snapshot.create", "cloud.snapshot.restore", "cloud.snapshot.delete", "cloud.billing.checkout", "cloud.migration.start"])
const CUT = "the provider call was cut off; retry with the same key"

const cases: Array<Obj> = []
/**
 * Requests a correct client never sends (both selectors, a key on link_token) and the VM bind agent's
 * POST /v1/cloud/bind (not a catalog op): kept out of `cases`, so op-driven client checks never see them.
 */
const backendOnly: Array<Obj> = []
const kase = (name: string, op: string, params: Obj, responses: Array<Obj>, opts: { key?: string; mutation?: boolean; principal?: Obj; note?: string } = {}) => {
  const c: Obj = { name, op, class: opts.key || opts.mutation ? "mutation" : "read", principal: opts.principal ?? (PERSON_OPS.has(op) ? SESSION_P : INSTALL_P), params }
  if (opts.key) c.idempotency_key = opts.key
  c.responses = responses
  if (opts.note) c.note = opts.note
  cases.push(c)
}

// ---- machine.list (paging)
kase("machine.list.first_page", "cloud.machine.list", { limit: 2 }, [readOk("cloud.machine.list", { machines: [M1, M2], next_cursor: "cur_page2", revision: "41" })])
kase("machine.list.second_page", "cloud.machine.list", { cursor: "cur_page2", limit: 2 }, [readOk("cloud.machine.list", { machines: [M3], next_cursor: null, revision: "41" })])
kase("machine.list.default", "cloud.machine.list", {}, [readOk("cloud.machine.list", { machines: [M1, M2, M3], next_cursor: null, revision: "41" })], {
  note: "No cursor = the first page; this team fits in one page."
})
kase("machine.list.unauthenticated", "cloud.machine.list", { limit: 1 }, [readErr(401, "Unauthenticated", "auth.unauthenticated", "sign in again")])

// ---- machine.get
kase("machine.get", "cloud.machine.get", { machine: vm(1) }, [readOk("cloud.machine.get", M1, "7")])
kase("machine.get.not_found", "cloud.machine.get", { machine: vm(9) }, [readErr(400, "BadRequest", "cloud.machine.not_found", "no such machine in this team")])
kase("machine.get.gone", "cloud.machine.get", { machine: vm(3) }, [readErr(400, "BadRequest", "cloud.machine.not_found", "no such machine in this team")], {
  note: "A machine the projection knows, deleted elsewhere."
})

// ---- machine.create
const M4 = machine(4, "new box", "provisioning", 42, { bound: false })
kase("machine.create", "cloud.machine.create", { name: "new box", size: SIZE }, replayPair("cloud.machine.create", "key-create-1", { machine: M4 }, "42"), {
  key: "key-create-1",
  note: "responses[1] is the same-key replay: the stored result, replayed true, no second machine."
})
kase(
  "machine.create.conflict",
  "cloud.machine.create",
  { name: "other box", size: SIZE },
  [opErr("cloud.machine.create", "key-create-1", "idempotency.conflict", "this idempotency key was already used for another request")],
  { key: "key-create-1" }
)
const M5 = machine(5, "cut box", "provisioning", 43, { bound: false })
const cut = opOk("cloud.machine.create", "key-create-cut", { machine: M5 }, "43", true)
kase(
  "machine.create.indeterminate",
  "cloud.machine.create",
  { name: "cut box", size: SIZE },
  [opErr("cloud.machine.create", "key-create-cut", "mutation.indeterminate", CUT, true), cut],
  { key: "key-create-cut", note: "responses[0] is the cut-off attempt; the same-key retry resumes from the ledger row (responses[1])." }
)
kase(
  "machine.create.plan_required",
  "cloud.machine.create",
  { name: "big box", size: { cpu: 4, memory_mb: 8192, disk_mb: 32768 } },
  [opErr("cloud.machine.create", "key-create-plan", "cloud.plan.required", "Cloud machines need a paid plan", false, { plan: PLAN_ID })],
  { key: "key-create-plan" }
)
kase(
  "machine.create.quota",
  "cloud.machine.create",
  { name: "sixth box", size: SIZE },
  [opErr("cloud.machine.create", "key-create-quota", "cloud.quota.exceeded", "this plan allows 5 active machines", false, { limit: 5, used: 5, resource: "active", plan: "max" })],
  { key: "key-create-quota" }
)
kase(
  "machine.create.size_locked",
  "cloud.machine.create",
  { name: "huge box", size: { cpu: 16, memory_mb: 65536, disk_mb: 262144 } },
  [opErr("cloud.machine.create", "key-create-locked", "cloud.size.locked", "this size needs another plan", false, { memory_mb: 65536, plan: "max" })],
  { key: "key-create-locked" }
)
kase(
  "machine.create.agent_forbidden",
  "cloud.machine.create",
  { name: "agent box", size: SIZE },
  [opErr("cloud.machine.create", "key-create-agent", "auth.forbidden", "an agent cannot create machines")],
  { key: "key-create-agent", principal: AGENT_P }
)
kase(
  "machine.create.install",
  "cloud.machine.create",
  { name: "from an install", size: SIZE },
  [opErr("cloud.machine.create", "key-create-install", "auth.forbidden", "creating a machine needs a signed-in person")],
  { key: "key-create-install", principal: INSTALL_P, note: "Money and destructive ops never use the default install grants." }
)
kase(
  "machine.create.install_confirmed",
  "cloud.machine.create",
  { name: "confirmed on the Mac", size: SIZE },
  [opErr("cloud.machine.create", "key-create-confirmed", "auth.forbidden", "creating a machine needs a signed-in person")],
  {
    key: "key-create-confirmed",
    principal: { kind: "install", origin_confirmation: "conf_pending_origin" },
    note: "PENDING ORIGIN: an install with a fresh single-use origin.confirmation token from the native confirmation sheet. Until the origin window lands this is refused like any install; after it, the expected answer is the machine.create success."
  }
)

// ---- rename, start, pause, resize, idle policy
kase("machine.rename", "cloud.machine.rename", { machine: vm(1), name: "renamed box" }, [opOk("cloud.machine.rename", "key-rename-1", { machine: { ...M1, name: "renamed box", revision: "47" } }, "47")], {
  key: "key-rename-1"
})
kase("machine.start", "cloud.machine.start", { machine: vm(2) }, [opOk("cloud.machine.start", "key-start-1", { machine: { ...M2, status: "starting", revision: "48" } }, "48")], {
  key: "key-start-1"
})
kase(
  "machine.start.quota",
  "cloud.machine.start",
  { machine: vm(2) },
  [opErr("cloud.machine.start", "key-start-quota", "cloud.quota.exceeded", "this plan allows 2 active machines", false, { limit: 2, used: 2, resource: "active", plan: PLAN_ID })],
  { key: "key-start-quota" }
)
kase("machine.pause", "cloud.machine.pause", { machine: vm(1) }, [opOk("cloud.machine.pause", "key-pause-1", { machine: { ...M1, status: "pausing", revision: "49" } }, "49")], {
  key: "key-pause-1"
})
const big = { cpu: 4, memory_mb: 8192, disk_mb: 32768 }
kase("machine.resize", "cloud.machine.resize", { machine: vm(1), size: big }, [opOk("cloud.machine.resize", "key-resize-1", { machine: { ...M1, size: big, revision: "50" } }, "50")], {
  key: "key-resize-1"
})
kase(
  "machine.resize.size_locked",
  "cloud.machine.resize",
  { machine: vm(1), size: { cpu: 16, memory_mb: 65536, disk_mb: 262144 } },
  [opErr("cloud.machine.resize", "key-resize-locked", "cloud.size.locked", "this size needs another plan", false, { memory_mb: 65536, plan: "max" })],
  { key: "key-resize-locked" }
)
kase(
  "machine.idle_policy.set",
  "cloud.machine.idle_policy.set",
  { machine: vm(1), idle_seconds: 3600 },
  [opOk("cloud.machine.idle_policy.set", "key-idle-1", { machine: { ...M1, idle_policy: { idle_seconds: 3600 }, revision: "51" } }, "51")],
  { key: "key-idle-1" }
)

// ---- delete
kase("machine.delete", "cloud.machine.delete", { machine: vm(2) }, replayPair("cloud.machine.delete", "key-delete-1", { deleted: true }, "52"), {
  key: "key-delete-1",
  note: "responses[1] is the same-key retry after the delete: {deleted: true} again."
})
kase("machine.delete.tombstone", "cloud.machine.delete", { machine: vm(2) }, [opOk("cloud.machine.delete", "key-delete-2", { deleted: true }, "52")], {
  key: "key-delete-2",
  note: "A new key after the delete: the tombstone answers {deleted: true} for 30 days."
})
kase(
  "machine.delete.indeterminate",
  "cloud.machine.delete",
  { machine: vm(3) },
  [opErr("cloud.machine.delete", "key-delete-cut", "mutation.indeterminate", CUT, true), opOk("cloud.machine.delete", "key-delete-cut", { deleted: true }, "53", true)],
  { key: "key-delete-cut" }
)
kase(
  "machine.delete.agent_forbidden",
  "cloud.machine.delete",
  { machine: vm(1) },
  [opErr("cloud.machine.delete", "key-delete-agent", "auth.forbidden", "an agent cannot delete machines")],
  { key: "key-delete-agent", principal: AGENT_P }
)
kase(
  "machine.delete.install",
  "cloud.machine.delete",
  { machine: vm(1) },
  [opErr("cloud.machine.delete", "key-delete-install", "auth.forbidden", "deleting a machine needs a signed-in person")],
  { key: "key-delete-install", principal: INSTALL_P, note: "Money and destructive ops never use the default install grants." }
)

// ---- connect_info (contract 1.7): no credential in a read
/** transport.md 3.1: the real derivation (fd7c:6d78::/32 + 96 bits of sha256(host id)). */
const overlay = new Map<number, string>()
for (const n of [1, 2, 4]) overlay.set(n, await overlayAddress(host(n)))
const connectInfo = (n: number, state: string, rev: number): Obj => ({
  machine: vm(n),
  host: host(n),
  epoch: 1,
  state,
  peer: { wg_public_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", overlay_address: overlay.get(n)!, vpc_endpoint: null, public_ipv6: null },
  gateway: null,
  services: ["daemon", "ssh"],
  daemon: { version: "0.40.0", capabilities: ["terminal", "files", "ports"] },
  revision: String(rev)
})
kase("machine.connect_info", "cloud.machine.connect_info", { machine: vm(1) }, [readOk("cloud.machine.connect_info", connectInfo(1, "running", 7), "7")])
kase("machine.connect_info.by_host", "cloud.machine.connect_info", { host: host(1) }, [readOk("cloud.machine.connect_info", connectInfo(1, "running", 7), "7")])
kase("machine.connect_info.paused", "cloud.machine.connect_info", { machine: vm(2) }, [readOk("cloud.machine.connect_info", connectInfo(2, "paused", 4), "4")], {
  note: "A paused machine is not an error: the result says state paused (contract 1.7)."
})
kase("machine.connect_info.not_bound", "cloud.machine.connect_info", { machine: vm(4) }, [readErr(400, "BadRequest", "cloud.machine.not_bound", "the machine is still provisioning")])

// ---- link_token (only `cmux link` calls it; the Cloud app never does). No idempotency key:
// each call mints a fresh token and nothing replays (the Worker gives the ledger a fresh key, so
// the response's idempotency_key is empty here).
/** A mint commits no stream event: no stream, no sequence, nothing a subscriber or cache sees. */
const mintOk = (value: Obj): Obj => ({
  http: { path: "/v1/ops", status: 200 },
  body: { ok: true, op: "cloud.machine.link_token", value, transaction: tx(), idempotency_key: "", replayed: false, stream: "", sequence: 0 }
})
const linkToken = (n: number) => ({ token: `lt_vector_${String(n).padStart(4, "0")}`, expires_at: 1790000300000 + n * 1000, host: host(1), epoch: 1, services: ["daemon", "ssh"] })
kase(
  "machine.link_token",
  "cloud.machine.link_token",
  { host: host(1), services: ["daemon", "ssh"] },
  [mintOk(linkToken(1)), mintOk(linkToken(2))],
  { mutation: true, note: "Two calls, two fresh tokens: no key, no replay." }
)
/** A refused mint: no stream, no key, no sequence (nothing was committed). */
const mintErr = (code: string, message: string, details?: Obj): Obj => ({
  http: { path: "/v1/ops", status: 200 },
  body: { ok: false, op: "cloud.machine.link_token", error: { code, message, retryable: false, ...(details ? { details } : {}) }, transaction: tx(), idempotency_key: "", replayed: false, stream: "", sequence: 0 }
})
kase("machine.link_token.not_bound", "cloud.machine.link_token", { host: host(4), services: ["ssh"] }, [mintErr("cloud.machine.not_bound", "the machine is still provisioning")], { mutation: true })
kase("machine.link_token.not_found", "cloud.machine.link_token", { host: host(9), services: ["ssh"] }, [mintErr("cloud.machine.not_found", "no such machine in this team")], { mutation: true })
kase(
  "machine.link_token.session_forbidden",
  "cloud.machine.link_token",
  { host: host(1), services: ["ssh"] },
  [mintErr("auth.forbidden", "link tokens are minted only for an install's cmux link")],
  { mutation: true, principal: SESSION_P, note: "Install principals only (LINK-RESOLVE): an app or page caller never holds a link token." }
)
kase(
  "machine.link_token.install_refused",
  "cloud.machine.link_token",
  { host: host(1), services: ["ssh"] },
  [mintErr("cloud.link.install_refused", "only the cli, mac app and ios installs mint link tokens", { install_kind: "web", allowed: ["cli", "mac", "ios"] })],
  { mutation: true, note: "CLOUD-LINK-FOLLOWUPS (2): a vm, daemon or web install never mints; the check runs before the machine lookup." }
)
backendOnly.push(...backendOnlyCases({ TEAM, INSTALL_P, vm, host, readErr }))

// ---- snapshots
const S1 = snapshot(1, 1, "nightly", 3)
const S2 = snapshot(2, 3, "before upgrade", 2)
kase("snapshot.list.machine", "cloud.snapshot.list", { machine: vm(1) }, [readOk("cloud.snapshot.list", { snapshots: [S1] })])
kase("snapshot.list.team", "cloud.snapshot.list", {}, [readOk("cloud.snapshot.list", { snapshots: [S1, S2] })])
const S3 = snapshot(3, 1, "checkpoint", 1, "creating")
kase("snapshot.create", "cloud.snapshot.create", { machine: vm(1), name: "checkpoint" }, [opOk("cloud.snapshot.create", "key-snap-1", { snapshot: S3 }, "1")], { key: "key-snap-1" })
kase(
  "snapshot.create.quota",
  "cloud.snapshot.create",
  { machine: vm(1), name: "one more" },
  [opErr("cloud.snapshot.create", "key-snap-quota", "cloud.quota.exceeded", "this plan keeps 10 saved snapshots", false, { limit: 10, used: 10, resource: "saved", plan: "max" })],
  { key: "key-snap-quota" }
)
const M6 = machine(6, "restored box", "provisioning", 44, { bound: false })
kase("snapshot.restore", "cloud.snapshot.restore", { snapshot: snap(1), name: "restored box" }, replayPair("cloud.snapshot.restore", "key-restore-1", { machine: M6 }, "44"), {
  key: "key-restore-1"
})
kase(
  "snapshot.restore.agent_forbidden",
  "cloud.snapshot.restore",
  { snapshot: snap(1), name: "agent box" },
  [opErr("cloud.snapshot.restore", "key-restore-agent", "auth.forbidden", "an agent cannot create machines")],
  { key: "key-restore-agent", principal: AGENT_P }
)
kase("snapshot.delete", "cloud.snapshot.delete", { snapshot: snap(1) }, replayPair("cloud.snapshot.delete", "key-snap-delete-1", { deleted: true }, "4"), { key: "key-snap-delete-1" })

// ---- plan and billing
const PLAN = {
  plan_id: PLAN_ID,
  upgrade_plan: "max",
  limits: { max_active: 5, max_saved: 10, memory_options_mb: [4096, 8192, 16384, 32768, 65536], locked_memory_options_mb: [65536], vm_hours_included: 500 },
  usage: { active: 2, saved: 3, vm_hours_used: 41.5, period_end: 1792000000000 }
}
kase("plan.get", "cloud.plan.get", {}, [readOk("cloud.plan.get", PLAN, "12")])
kase("billing.checkout", "cloud.billing.checkout", { plan: PLAN_ID }, [opOk("cloud.billing.checkout", "key-checkout-1", { url: "https://checkout.example.com/session/cs_vector_0001" }, "13")], {
  key: "key-checkout-1"
})
kase(
  "billing.checkout.agent_forbidden",
  "cloud.billing.checkout",
  { plan: PLAN_ID },
  [opErr("cloud.billing.checkout", "key-checkout-agent", "auth.forbidden", "an agent cannot start a checkout")],
  { key: "key-checkout-agent", principal: AGENT_P }
)

// ---- migration and upgrade
const M7 = machine(7, "classic box", "running", 2, { bound: false, classic: true })
kase("migration.status", "cloud.migration.status", {}, [readOk("cloud.migration.status", { state: "available", classic_count: 1, imported: [vm(7)] }, "3")])
kase("migration.start", "cloud.migration.start", {}, [opOk("cloud.migration.start", "key-migrate-1", { state: "moving" }, "4")], { key: "key-migrate-1" })
kase(
  "migration.start.unavailable",
  "cloud.migration.start",
  {},
  [opErr("cloud.migration.start", "key-migrate-none", "cloud.migration.unavailable", "there is nothing to move for this account")],
  { key: "key-migrate-none" }
)
kase(
  "migration.start.agent_forbidden",
  "cloud.migration.start",
  {},
  [opErr("cloud.migration.start", "key-migrate-agent", "auth.forbidden", "an agent cannot start a migration")],
  { key: "key-migrate-agent", principal: AGENT_P }
)
kase("machine.upgrade", "cloud.machine.upgrade", { machine: vm(7) }, [opOk("cloud.machine.upgrade", "key-upgrade-1", { machine: { ...M7, classic: false, host: host(7), revision: "54" } }, "54")], {
  key: "key-upgrade-1"
})
kase(
  "machine.upgrade.not_classic",
  "cloud.machine.upgrade",
  { machine: vm(1) },
  [opErr("cloud.machine.upgrade", "key-upgrade-new", "cloud.machine.not_classic", "this machine already runs cmux-next")],
  { key: "key-upgrade-new" }
)
kase(
  "machine.upgrade.failed",
  "cloud.machine.upgrade",
  { machine: vm(7) },
  [opErr("cloud.machine.upgrade", "key-upgrade-fail", "cloud.upgrade.failed", "the daemon install failed; the classic machine still works")],
  { key: "key-upgrade-fail" }
)

// ---- rescue shell (request and response only)
kase("shell.open", "cloud.shell.open", { machine: vm(1), cols: 120, rows: 40 }, [opOk("cloud.shell.open", "key-shell-1", { stream: "wst_w0000000000000000001" }, "7")], { key: "key-shell-1" })
kase(
  "shell.open.paused",
  "cloud.shell.open",
  { machine: vm(2), cols: 120, rows: 40 },
  [opErr("cloud.shell.open", "key-shell-paused", "cloud.machine.paused", "the machine is paused")],
  { key: "key-shell-paused" }
)

const events: Array<Obj> = []
const event = (name: string, ev: string, data: Obj, note?: string) => {
  const e: Obj = { name, event: ev, stream: STREAM, seq: seq(), data }
  if (note) e.note = note
  events.push(e)
}
event("machine.upsert.newer", "cloud.machine.upsert", { machine: { ...M1, status: "pausing", revision: "55" } })
event("machine.upsert.stale", "cloud.machine.upsert", { machine: { ...M1, status: "running", revision: "6" } }, "Older than the projection's revision 7 (or 55): dropped.")
event("machine.upsert.bound", "cloud.machine.upsert", { machine: { ...M4, status: "running", host: host(4), revision: "46" } }, "Provisioning done: the host is bound.")
event("machine.upsert.new", "cloud.machine.upsert", { machine: machine(8, "made elsewhere", "provisioning", 45, { bound: false }) })
event("machine.removed", "cloud.machine.removed", { machine: vm(3), revision: "56" })
event("machine.removed.stale", "cloud.machine.removed", { machine: vm(1), revision: "3" }, "Older than the record: dropped (the machine stays).")
event("snapshot.upsert", "cloud.snapshot.upsert", { snapshot: { ...S3, status: "ready", revision: "2" } })
event("snapshot.removed", "cloud.snapshot.removed", { snapshot: snap(1), revision: "4" })
event("plan.changed", "cloud.plan.changed", { plan: PLAN })

const doc = {
  $comment:
    "cmux.wire/1 vectors for the cmux-next Cloud ops (plans/cmux-next/cloud-client-contract.md 1.3 and 1.4). Shared by the client tests (first-party-apps/cloud/server) and the backend tests. Synthetic data only. Generated by backend/packages/protocol/scripts/export-cloud-vectors.ts.",
  protocol: "cmux.wire/1",
  version: 1,
  identities: { team: TEAM, user: USER, install: INSTALL, agent: AGENT },
  conventions: {
    request: "POST http.path with {op, params, idempotency_key?}; reads have no key. `backend_only` bind cases POST params as the whole body to /v1/cloud/bind with no bearer (the one-time bind token is the credential).",
    responses: "One entry per attempt with the same (principal, op, params, idempotency_key): attempt i gets responses[i], later attempts the last entry.",
    read_error: "A read error is the HTTP error body {_tag, code, message} at http.status.",
    principal: "kind install or session; agent set = a chief token (claim agt).",
    revision:
      "Decimal string: the team owner's (CloudDO) event sequence at the entity's last change, so entity and list revisions compare. A client drops an event or answer older than what it holds."
  },
  cases,
  events,
  backend_only: backendOnly
}

const out = fileURLToPath(new URL("../../../catalog/cloud-vectors.json", import.meta.url))
const text = `${JSON.stringify(doc, null, 2)}\n`
if (process.argv.includes("--check")) {
  let current = ""
  try {
    current = readFileSync(out, "utf8")
  } catch {}
  if (current !== text) {
    console.error(`vectors drift: ${out} differs from scripts/export-cloud-vectors.ts; run bun run catalog:vectors`)
    process.exit(1)
  }
  console.log(`vectors ok: ${cases.length} cases, ${events.length} events`)
} else {
  writeFileSync(out, text)
  console.log(`wrote ${out}: ${cases.length} cases, ${events.length} events`)
}
