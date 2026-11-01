import type { OwnerFrame, Principal } from "@cmux/ownership"
import { cloudOpByName } from "@cmux/protocol"
import { conversationMutate, conversationRead } from "../../api/src/home-routes.ts"
import { handleAttachmentCommit, handleAttachmentDerived, handleAttachmentDirectPart, handleAttachmentDownload, handleAttachmentIntent, handleAttachmentMultipartComplete, handleAttachmentMultipartPart, handleAttachmentUpload, handleAttachmentUrl } from "../../api/src/home-attachments.ts"
import { linkVerifiedAddress } from "../../api/src/home-requests.ts"
import { presignUrl } from "../../api/src/r2-presign.ts"
import type { SubmitResult } from "../../api/src/owner-do.ts"
import type { Admission, Admitted } from "./admission.ts"
import type { RosterMember } from "./roster-do.ts"
import type { ServerRuntime } from "./server-env.ts"

/** Version of the self-hosted server protocol subset (GET /v1/selfhost/info). */
export const SELFHOST_API_VERSION = 1

/** UserDO ops (besides `inbox.*`) a self-hosted server runs. */
const USER_OPS = new Set(["user.ensure", "home.settings.set"])
/** Attachment paths (home-attachments.ts), as the Worker routes them (index.ts). */
const CONV = "conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26}"
const UPLOAD = new RegExp(`^/v1/home/attachments/upload/(${CONV})/([A-Za-z0-9_.-]{1,256})$`)
const MULTIPART = new RegExp(`^/v1/home/attachments/multipart/(${CONV})/([A-Za-z0-9_.-]{1,256})$`)
const DERIVED = new RegExp(`^/v1/home/attachments/(poster|preview)/(${CONV})/([A-Za-z0-9_.-]{1,256})$`)
const DOWNLOAD = new RegExp(`^/v1/home/attachments/(${CONV})/([0-9a-f]{32})$`)
/** The conversation socket path: `/v1/wire/conv/<id>`. */
const CONV_WIRE = /^\/v1\/wire\/conv\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})$/

type OwnerStub = {
  submit(entity: string, p: Principal, frame: unknown): Promise<SubmitResult>
  submitInbox(entity: string, p: Principal, frame: unknown): Promise<SubmitResult>
  readInbox(entity: string, p: Principal, op: string, params: Record<string, unknown>): Promise<{ ok: boolean; value?: unknown; revision?: string; code?: string; message?: string }>
  mayAccept(entity: string, p: Principal): Promise<boolean>
}
type RosterStub = { join(user: string, login: string, name: string): Promise<boolean>; members(): Promise<Array<RosterMember>> }

/** A socket the router asks the server to upgrade: which object and principal it belongs to. */
export interface UpgradeTarget {
  readonly binding: "CONVERSATION_DO" | "USER_DO"
  readonly entity: string
  readonly principal: Principal
}

/** The tagged error bodies of the hosted API (protocol api.ts), with the same HTTP statuses. */
const tagged = (tag: "BadRequest" | "Forbidden" | "OwnerUnreachable" | "Unauthenticated", code: string, message: string, status: number, extra: Record<string, unknown> = {}) =>
  Response.json({ _tag: tag, code, message, ...extra }, { status })
const badRequest = (message: string, code = "validation.invalid") => tagged("BadRequest", code, message, 400)
const forbidden = (message: string) => tagged("Forbidden", "auth.forbidden", message, 403)
const unreachable = (e: unknown) => tagged("OwnerUnreachable", "owner.unreachable", String(e).slice(0, 300), 503, { retryable: true })

/** The hosted API's mutation response (http.ts toResponse). */
const toResponse = (op: string, frames: ReadonlyArray<OwnerFrame>) => {
  const reply = frames.find((f) => f.t === "result" || f.t === "reject") as (OwnerFrame & { t: "result" | "reject" }) | undefined
  if (!reply) return { ok: false, op, error: { code: "owner.unreachable", message: "no reply", retryable: true }, transaction: "", idempotency_key: "", replayed: false, stream: "", sequence: 0 }
  const settled = frames.find((f) => f.t === "request-settled") as { stream?: string; sequence?: number } | undefined
  const r = reply as unknown as { t: string; value?: unknown; revision?: string; code?: string; message?: string; retryable?: boolean; details?: unknown; tx: string; idempotency_key: string; replayed: boolean }
  return {
    ok: r.t === "result",
    op,
    ...(r.t === "result" ? { value: r.value, revision: r.revision } : { error: { code: r.code, message: r.message, retryable: r.retryable, ...(r.details === undefined ? {} : { details: r.details }) } }),
    transaction: r.tx,
    idempotency_key: r.idempotency_key,
    replayed: r.replayed,
    stream: settled?.stream ?? "",
    sequence: settled?.sequence ?? 0
  }
}

/**
 * The chat subset of the hosted Worker on a self-hosted server: the same paths, bodies and
 * answers (`/v1/ops`, `/v1/read`, `/v1/wire/conv/<id>`, `/v1/wire/user`) plus `/v1/selfhost/*`.
 * The principal comes from Tailscale admission, never from a header or a frame.
 */
export class Router {
  /** Logins this process already ensured (user.ensure, roster, address link). */
  private readonly ensured = new Map<string, Promise<void>>()

  constructor(
    private readonly server: ServerRuntime,
    private readonly admission: Admission,
    private readonly info: () => { server_name: string; url: string | null }
  ) {}

  private get env() {
    return this.server.env as never
  }

  private user(user: string): OwnerStub {
    return this.server.runtime.stub("USER_DO", user) as unknown as OwnerStub
  }

  private get roster(): RosterStub {
    return this.server.runtime.stub("ROSTER_DO", "roster") as unknown as RosterStub
  }

  /** First request of a login in this process: roster entry, account (user.ensure) and its verified address. */
  private ensure(a: Admitted): Promise<void> {
    let p = this.ensured.get(a.login)
    if (!p) {
      p = (async () => {
        const user = a.principal.user!
        await this.roster.join(user, a.login, a.display_name)
        await this.user(user).submit(user, a.principal, { t: "op", op: "user.ensure", params: {}, idempotency_key: `selfhost-ensure:${user}`, origin: "script" })
        await linkVerifiedAddress(this.env, a.principal)
      })()
      // A failed ensure is tried again on the next request.
      p.catch(() => this.ensured.delete(a.login))
      this.ensured.set(a.login, p)
    }
    return p
  }

  /** Admits the peer and answers the request, or names the socket to upgrade. */
  async handle(request: Request, peer: string): Promise<Response | UpgradeTarget> {
    const url = new URL(request.url)
    if (url.pathname === "/healthz") return Response.json({ ok: true })
    const admitted = await this.admission.admit(peer)
    if (!admitted.ok) return tagged("Forbidden", "auth.forbidden", "not_allowed", 403)
    try {
      await this.ensure(admitted)
    } catch (e) {
      return unreachable(e)
    }
    const principal = admitted.principal
    if (url.pathname === "/v1/selfhost/info" && request.method === "GET") {
      const i = this.info()
      return Response.json({ kind: "selfhost", api_version: SELFHOST_API_VERSION, user_id: principal.user, login: admitted.login, display_name: admitted.display_name, server_name: i.server_name, server_id: this.server.serverId, url: i.url })
    }
    if (url.pathname === "/v1/selfhost/members" && request.method === "GET") {
      const members = await this.roster.members()
      return Response.json({ members: members.map((m) => ({ user_id: m.user, login: m.login, display_name: m.display_name })) })
    }
    if (url.pathname.startsWith("/v1/home/attachments/")) {
      const env = this.env
      if (url.pathname === "/v1/home/attachments/intent" && request.method === "POST") return handleAttachmentIntent(request, env, presignUrl, principal)
      if (url.pathname === "/v1/home/attachments/commit" && request.method === "POST") return handleAttachmentCommit(request, env, principal)
      if (url.pathname === "/v1/home/attachments/multipart/complete" && request.method === "POST") return handleAttachmentMultipartComplete(request, env, principal)
      if (url.pathname === "/v1/home/attachments/url" && request.method === "POST") return handleAttachmentUrl(request, env, principal)
      const up = UPLOAD.exec(url.pathname)
      if (up && request.method === "PUT") return handleAttachmentUpload(request, env, up[1]!, up[2]!)
      const multipart = MULTIPART.exec(url.pathname)
      if (multipart && request.method === "PUT") return handleAttachmentMultipartPart(request, env, multipart[1]!, multipart[2]!)
      if (multipart && request.method === "POST") return handleAttachmentDirectPart(request, env, multipart[1]!, multipart[2]!)
      const d = DERIVED.exec(url.pathname)
      if (d && request.method === "PUT") return handleAttachmentDerived(request, env, d[1] as "poster" | "preview", d[2]!, d[3]!)
      const file = DOWNLOAD.exec(url.pathname)
      if (file && (request.method === "GET" || request.method === "HEAD")) return handleAttachmentDownload(request, env, file[1]!, file[2]!)
    }
    if (url.pathname === "/v1/ops" && request.method === "POST") return this.mutate(principal, request)
    if (url.pathname === "/v1/read" && request.method === "POST") return this.read(principal, request)
    if (request.headers.get("upgrade")?.toLowerCase() === "websocket") {
      if (url.pathname === "/v1/wire/user") return { binding: "USER_DO", entity: principal.user!, principal }
      const conv = CONV_WIRE.exec(url.pathname)
      if (conv) {
        const ok = await (this.server.runtime.stub("CONVERSATION_DO", conv[1]!) as unknown as OwnerStub).mayAccept(conv[1]!, principal)
        return ok ? { binding: "CONVERSATION_DO", entity: conv[1]!, principal } : new Response("forbidden", { status: 403 })
      }
    }
    return Response.json({ _tag: "NotFound", code: "not_on_selfhost", message: `${url.pathname} is not on a self-hosted chat server` }, { status: 404 })
  }

  private async body(request: Request): Promise<{ op?: unknown; params?: unknown; idempotency_key?: unknown; origin?: unknown; expected_revision?: unknown } | null> {
    try {
      const b = (await request.json()) as unknown
      return b && typeof b === "object" ? (b as Record<string, unknown>) : null
    } catch {
      return null
    }
  }

  private async mutate(principal: Principal, request: Request): Promise<Response> {
    const b = await this.body(request)
    if (!b || typeof b.op !== "string") return badRequest("a JSON body with `op` is required")
    const def = cloudOpByName.get(b.op)
    if (!def || def.class !== "mutation") return badRequest(`unknown mutation ${b.op}`)
    if (typeof b.idempotency_key !== "string" || !b.idempotency_key) return badRequest("mutations require idempotency_key")
    const frame = {
      t: "op" as const,
      op: b.op,
      params: b.params ?? {},
      idempotency_key: b.idempotency_key,
      origin: typeof b.origin === "string" ? b.origin : "cli",
      ...(typeof b.expected_revision === "string" ? { expected_revision: b.expected_revision } : {})
    }
    try {
      if (def.owner === "cloud:ConversationDO") return Response.json(toResponse(b.op, (await conversationMutate(this.env, principal, frame as never)).frames))
      if (b.op.startsWith("inbox.")) return Response.json(toResponse(b.op, (await this.user(principal.user!).submitInbox(principal.user!, principal, frame)).frames))
      if (def.owner === "cloud:UserDO" && USER_OPS.has(b.op)) return Response.json(toResponse(b.op, (await this.user(principal.user!).submit(principal.user!, principal, frame)).frames))
    } catch (e) {
      return unreachable(e)
    }
    return badRequest(`${b.op} is not on a self-hosted chat server`)
  }

  private async read(principal: Principal, request: Request): Promise<Response> {
    const b = await this.body(request)
    if (!b || typeof b.op !== "string") return badRequest("a JSON body with `op` is required")
    const def = cloudOpByName.get(b.op)
    if (!def || def.class !== "read") return badRequest(`unknown read ${b.op}`)
    try {
      let r: { ok: boolean; value?: unknown; revision?: string; code?: string; message?: string }
      let stream: string
      if (def.owner === "cloud:ConversationDO") {
        r = (await conversationRead(this.env, principal, b.op, b.params)) as typeof r
        stream = `conv:${String((b.params as { conversation?: unknown } | null)?.conversation ?? "")}`
      } else if (b.op.startsWith("inbox.")) {
        r = await this.user(principal.user!).readInbox(principal.user!, principal, b.op, (b.params ?? {}) as Record<string, unknown>)
        stream = `inbox:${principal.user}`
      } else return badRequest(`${b.op} is not on a self-hosted chat server`)
      if (!r.ok) {
        const code = r.code ?? "auth.forbidden"
        return code === "auth.forbidden" ? forbidden(r.message ?? "") : badRequest(r.message ?? "", code)
      }
      return Response.json({ op: b.op, value: r.value, stream, revision: r.revision ?? "" })
    } catch (e) {
      return unreachable(e)
    }
  }
}
