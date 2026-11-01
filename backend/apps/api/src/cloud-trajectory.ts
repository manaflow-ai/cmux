import type { Principal } from "@cmux/ownership"
import { authenticate } from "./auth.ts"
import { isNativePath, isSessionId, NATIVE_CHUNK_MAX_BYTES, type TrajectoryListPage, type TrajectoryRefusal, type TrajectoryResult } from "./cloud-trajectory-store.ts"
import type { Env } from "./env.ts"
import { isMachineInstallKind } from "./machine-installs.ts"
import { ssoGate } from "./policy-gate.ts"
import { principalForOwner, selectTeam, TEAM_HEADER } from "./team-select.ts"

/**
 * ACP chat trajectories outside the VM (#25584), as plain HTTP routes outside the op path (like
 * /v1/cloud/machines/{machine}/acpmux): a chat's log is a stream of records, not an op.
 *
 *   POST /v1/cloud/machines/{machine}/trajectories/append       {session, generation, meta?, lines[]}
 *   POST /v1/cloud/machines/{machine}/trajectories/native       {session, generation, label, path, offset, data (base64)}
 *   POST /v1/cloud/machines/{machine}/trajectories/list         {page_protocol?: 2, after_session?}
 *   POST /v1/cloud/machines/{machine}/trajectories/read         {session, after_seq?, limit?}
 *   POST /v1/cloud/machines/{machine}/trajectories/native-read  {session, label, path, offset}
 *
 * Writes: only the VM install bound to the machine (`cloud.vm.*`'s gate, cloud-vm.ts vmGate), into that
 * machine's own store (one TrajectoryDO per team and machine, so two machines never write one log).
 * Reads: that VM install, or the machine's creator (a session, or one of the creator's own installs with
 * the read class). A read body with `from: "parent"` (the VM install only) reads the store of the machine
 * this one was restored from, when the same person created both (domains/cloud.ts trajectory_parent):
 * the replacement imports the chats its snapshot did not have and keeps writing them into its own store.
 *
 * Off unless CLOUD_TRAJECTORIES_ENABLED is "1" (development and tests): answers 404
 * cloud.trajectory.disabled, which the VM's mirror reads as "try again much later".
 */
export const TRAJECTORY_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/trajectories\/(append|native|list|read|native-read)$/

export type TrajectoryAction = "append" | "native" | "list" | "read" | "native-read"

/** Base64 of one native chunk plus the JSON around it, or a batch of records. */
const BODY_MAX_BYTES = 8 * 1024 * 1024
const APPEND_MAX_LINES = 2000

/** CloudDO's answer: the machine whose store this principal may use (null: a restore without a source), or why not. */
export type TrajectoryScope = { readonly ok: true; readonly store: string | null } | { readonly ok: false; readonly status: number; readonly code: string; readonly message: string }

type CloudStub = { trajectoryScope(entity: string, p: Principal, machine: string, write: boolean, parent: boolean): Promise<TrajectoryScope> }
type Store = {
  append(session: string, generation: number, meta: unknown, lines: ReadonlyArray<string>): Promise<TrajectoryResult<{ last_seq: number }>>
  appendNative(session: string, generation: number, label: string, path: string, offset: number, data: Uint8Array): Promise<TrajectoryResult<{ size: number }>>
  list(afterSession: string | null): Promise<TrajectoryListPage>
  read(session: string, afterSeq: number, limit: number): Promise<TrajectoryResult<unknown>>
  readNative(session: string, label: string, path: string, offset: number): Promise<TrajectoryResult<{ generation: number; revision: string; size: number; data: Uint8Array }>>
}

const NO_STORE = { "cache-control": "no-store" }
const answer = (status: number, code: string, message: string, details?: unknown) => Response.json({ ok: false, error: { code, message, ...(details === undefined ? {} : { details }) } }, { status, headers: NO_STORE })
const ok = (value: unknown) => Response.json({ ok: true, value }, { headers: NO_STORE })

const REFUSAL_STATUS: Readonly<Record<TrajectoryRefusal["code"], [number, string]>> = {
  "cloud.trajectory.gap": [409, "the log has a gap: send from one past last_seq"],
  "cloud.trajectory.conflict": [409, "a kept record differs from the one sent"],
  "cloud.trajectory.stale_generation": [409, "a newer chat with this id is kept"],
  "cloud.trajectory.offset": [409, "the file's kept size differs from the offset"],
  "cloud.trajectory.not_found": [404, "no such chat is kept"],
  "cloud.trajectory.full": [507, "this machine's kept chats reached their limit"],
  "validation.invalid": [400, "invalid trajectory request"]
}

const refused = (r: TrajectoryRefusal) => {
  const [status, message] = REFUSAL_STATUS[r.code]
  const { code, ...details } = r
  return answer(status, code, "message" in r ? r.message : message, Object.keys(details).length > 0 && !("message" in r) ? details : undefined)
}

const reply = <A>(r: TrajectoryResult<A>, map: (a: A) => unknown = (a) => a) => (r.ok ? ok(map(r.value)) : refused(r.refusal))

const toBase64 = (bytes: Uint8Array) => {
  let s = ""
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

const fromBase64 = (text: string): Uint8Array | null => {
  try {
    const s = atob(text)
    const out = new Uint8Array(s.length)
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i)
    return out
  } catch {
    return null
  }
}

/** The caller's principal for the team's CloudDO, or the refusal answer. */
const principalOf = async (request: Request, env: Env): Promise<Principal | Response> => {
  const auth = request.headers.get("authorization") ?? ""
  const token = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!token?.user || !token.team) return answer(401, "auth.unauthenticated", "a token is required")
  if (token.agent !== undefined) return answer(403, "auth.forbidden", "agents cannot read or write chat trajectories")
  // Only a personal machine's own install among machine installs (machine-installs.ts); a team VM's is refused here.
  if (isMachineInstallKind(token.install_kind) && token.install_kind !== "vm") return answer(403, "auth.forbidden", "a machine install has no access to chats")
  let p: Principal = token
  if (token.kind === "session") {
    const selected = await selectTeam(env, { ...token, user: token.user, team: token.team }, request.headers.get(TEAM_HEADER))
    if (!selected.ok) return answer(selected.code === "owner.unreachable" ? 503 : 403, selected.code, selected.message)
    const gate = await ssoGate(env, selected.principal).catch(() => null)
    if (!gate) return answer(503, "owner.unreachable", "the sign-in policy could not be checked; retry")
    if (gate.refusal) return answer(403, gate.refusal.code, gate.refusal.message)
    const { stack_session: _session, email_domain: _domain, ...authed } = gate.principal
    p = authed
  }
  const granted = await principalForOwner(env, "cloud:CloudDO", p).catch(() => null)
  if (granted === null) return answer(503, "owner.unreachable", "team membership could not be checked; retry")
  if (!granted || "refused" in granted) return answer(403, "auth.forbidden", "no access to this team's machines")
  return granted
}

const readJson = async (request: Request): Promise<Record<string, unknown> | null> => {
  const declared = Number(request.headers.get("content-length") ?? "NaN")
  if (!(declared >= 0 && declared <= BODY_MAX_BYTES)) return null
  try {
    const text = await request.text()
    if (text.length > BODY_MAX_BYTES) return null
    const v = JSON.parse(text === "" ? "{}" : text) as unknown
    return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null
  } catch {
    return null
  }
}

const isCount = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0

export const handleCloudTrajectory = async (request: Request, env: Env, machine: string, action: TrajectoryAction): Promise<Response> => {
  if (env.CLOUD_TRAJECTORIES_ENABLED !== "1") return answer(404, "cloud.trajectory.disabled", "chat trajectories are not kept on this deployment")
  if (request.method !== "POST") return Response.json({ ok: false, error: { code: "validation.invalid", message: "POST only" } }, { status: 405, headers: { allow: "POST" } })
  if (request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() !== "application/json") return answer(400, "validation.invalid", "the body must be JSON")
  const principal = await principalOf(request, env)
  if (principal instanceof Response) return principal
  const body = await readJson(request)
  if (!body) return answer(400, "validation.invalid", "invalid trajectory request")
  const write = action === "append" || action === "native"
  let scope: TrajectoryScope
  try {
    const cloud = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(principal.team!)) as unknown as CloudStub
    scope = await cloud.trajectoryScope(principal.team!, principal, machine, write, body.from === "parent")
  } catch {
    return answer(503, "owner.unreachable", "the Cloud service could not be reached; retry")
  }
  if (!scope.ok) return answer(scope.status, scope.code, scope.message)
  if (scope.store === null) return action === "list" ? ok({ sessions: [], has_more: false, next_after_session: null }) : answer(404, "cloud.trajectory.not_found", "this machine was not restored from one of yours")
  const store = env.TRAJECTORY_DO.get(env.TRAJECTORY_DO.idFromName(`${principal.team!}/${scope.store}`)) as unknown as Store
  if (action === "list") {
    const after = body.after_session
    if (after !== undefined && !isSessionId(after)) return answer(400, "validation.invalid", "invalid list cursor")
    const page = await store.list(typeof after === "string" ? after : null)
    // A guest built before pagination ignores has_more. A full old-style first page would
    // silently omit chat 501+ during restore; refuse it unless the caller understands cursors.
    if (page.has_more && body.page_protocol !== 2) return answer(409, "cloud.trajectory.pagination_required", "upgrade the Cloud VM session host to read every saved chat")
    return ok(page)
  }
  const session = body.session
  if (!isSessionId(session)) return answer(400, "validation.invalid", "invalid session id")
  switch (action) {
    case "append": {
      const { generation, meta, lines } = body
      if (!isCount(generation)) return answer(400, "validation.invalid", "invalid generation")
      if (meta !== undefined && (typeof meta !== "object" || meta === null || Array.isArray(meta) || (meta as { id?: unknown }).id !== session || (meta as { createdAt?: unknown }).createdAt !== generation)) return answer(400, "validation.invalid", "the session record must be this session's, at this generation")
      if (!Array.isArray(lines) || lines.length > APPEND_MAX_LINES || !lines.every((l) => typeof l === "string")) return answer(400, "validation.invalid", "invalid records")
      return reply(await store.append(session, generation, meta, lines as Array<string>))
    }
    case "native": {
      const { generation, label, path, offset, data } = body
      if (!isCount(generation) || !isCount(offset) || !isNativePath(label, path) || typeof data !== "string") return answer(400, "validation.invalid", "invalid native file write")
      const bytes = fromBase64(data)
      if (!bytes || bytes.byteLength > NATIVE_CHUNK_MAX_BYTES) return answer(400, "validation.invalid", "invalid native file chunk")
      return reply(await store.appendNative(session, generation, label as string, path, offset, bytes))
    }
    case "read": {
      const after = body.after_seq ?? 0
      const limit = body.limit ?? 1000
      if (!isCount(after) || !isCount(limit)) return answer(400, "validation.invalid", "invalid read")
      return reply(await store.read(session, after, limit))
    }
    case "native-read": {
      const { label, path, offset } = body
      if (!isCount(offset) || !isNativePath(label, path)) return answer(400, "validation.invalid", "invalid native file read")
      return reply(await store.readNative(session, label as string, path, offset), (v) => ({ generation: v.generation, revision: v.revision, size: v.size, data: toBase64(v.data) }))
    }
  }
}
