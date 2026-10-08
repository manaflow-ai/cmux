import { authenticate, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import { apiHandler } from "./http.ts"
import { handleAutomationHook } from "./ingress/automation-hook.ts"
import { handleProviderHook } from "./ingress/provider-hook.ts"
import { handleGooglePubsub } from "./ingress/google-hooks.ts"
import { handleSsoDiscover } from "./sso-discover.ts"
import { handleInviteCard, handleInvitePreview } from "./home-routes.ts"
import { handleAttachmentCommit, handleAttachmentDownload, handleAttachmentIntent, handleAttachmentDerived, handleAttachmentUpload, handleAttachmentUrl } from "./home-attachments.ts"
import { CARD_PATH, handleContactCard, handleSendblueHook } from "./home-text.ts"
import { handleOutboxReplay } from "./admin-outbox.ts"
import { handleCloudAbandonedClear } from "./cloud-admin.ts"
import { handleTeamVmAdmin } from "./team-vm-admin.ts"
import { signInRules, ssoGate, versionRefusal } from "./policy-gate.ts"
import type { PresenceKeyBody } from "./user-do.ts"
import { handlePairBegin, handlePairWait } from "./pair-routes.ts"
import { handleSsoCallback, handleSsoRedeem, handleSsoStart } from "./sso-routes.ts"
import { sweepDeps, sweepFeedText } from "./feed-sweep.ts"

export { AccountIndexDO } from "./account-index-do.ts"
export { AddressDO } from "./address-do.ts"
export { ConversationDO } from "./conversation-do.ts"
export { MuxDO } from "./mux-do.ts"
export { DomainDO } from "./domain-do.ts"
export { PairingDO } from "./pairing-do.ts"
export { HostDO } from "./host-do.ts"
export { TeamVmDO } from "./team-vm-do.ts"
export { CloudDO } from "./cloud-do.ts"
import { handleCloudBind, handleCloudKeyset } from "./cloud-link.ts"
export { AutomationRunWorkflow } from "./automation-workflow.ts"
export { AutomationTail } from "./automation-tail.ts"
export { AutomationEgress } from "./automation-egress.ts"
export { ConnectionDO } from "./connection-do.ts"
export { FeedDO } from "./feed-do.ts"
export { SchedulerDO } from "./scheduler-do.ts"
export { TeamDO } from "./team-do.ts"
export { UserDO } from "./user-do.ts"
export { UsageMeterDO } from "./usage-meter-do.ts"

/** The SSO gate could not reach a TeamDO or UserDO: retryable, never a 500 (cx-44j.51). */
const gateUnreachable = (e: unknown) => {
  console.error(JSON.stringify({ msg: "sso gate unreachable", error: String(e) }))
  return Response.json({ error: { code: "owner.unreachable", message: "the sign-in policy could not be checked; retry", retryable: true } }, { status: 503 })
}

/**
 * WebSocket gateway: `GET /v1/wire/{user|team|feed|cloud}` and `/v1/wire/conv/<conversation>` with subprotocols
 * `cmux.wire.v1, bearer.<token>` (browsers cannot set headers; the token stays
 * out of the URL and logs). The Worker authenticates and passes the principal
 * to the owner DO; frames never carry identity.
 */
const wire = async (request: Request, env: Env, scope: string, conversation?: string /* or agent for mux */): Promise<Response> => {
  const protocols = (request.headers.get("Sec-WebSocket-Protocol") ?? "").split(",").map((s) => s.trim())
  const token = protocols.find((p) => p.startsWith("bearer."))?.slice("bearer.".length)
  const authenticated = await authenticate(env, token)
  if (!authenticated?.user || !authenticated.team) return new Response("unauthenticated", { status: 401 })
  // A VM install has no socket (review P1): it reaches only the cloud.vm.* ops.
  if (authenticated.install_kind === "vm") return Response.json({ error: { code: "auth.forbidden", message: "a VM install has no socket" } }, { status: 403 })
  // Team policy (P17-4): SSO (own team and the email domain's team), minimum client version for every connect.
  let rules: Awaited<ReturnType<typeof signInRules>>, gate: Awaited<ReturnType<typeof ssoGate>>
  try {
    ;[rules, gate] = [await signInRules(env, authenticated.team, authenticated.user), await ssoGate(env, authenticated)]
  } catch (e) {
    return gateUnreachable(e)
  }
  // The Stack session id and the install's email domain serve only this gate; owners never receive them.
  const { stack_session: _session, email_domain: _domain, ...authed } = gate.principal
  const refused = gate.refusal ?? versionRefusal(request.headers.get("x-cmux-client-version"), rules)
  if (refused) return Response.json({ error: refused }, { status: 403 })
  // TeamDO and FeedDO cannot see UserDO's revocations; resolve the grant first (UserDO checks its own installs).
  const principal = scope === "user" ? authed : await withGrantClasses(env, authed)
  if (!principal) return new Response("forbidden", { status: 403 })
  const [ns, entity] =
    scope === "user"
      ? [env.USER_DO, principal.user]
      : scope === "team"
        ? [env.TEAM_DO, principal.team]
        : scope === "feed"
          ? [env.FEED_DO, principal.user]
          : scope === "cloud"
            ? [env.CLOUD_DO, principal.team]
          : scope === "conv"
            ? [env.CONVERSATION_DO, conversation]
            : scope === "mux"
              ? [env.MUX_DO, conversation]
              : [undefined, undefined]
  if (!ns || !entity) return new Response("not found", { status: 404 })
  const headers = new Headers(request.headers)
  headers.set("x-cmux-entity", entity)
  headers.set("x-cmux-principal", JSON.stringify(principal))
  const stub = (ns as DurableObjectNamespace).get((ns as DurableObjectNamespace).idFromName(entity))
  return stub.fetch(new Request(request.url, { headers, method: "GET" }))
}

/** POST /v1/presence-key with the install's own token (home-messaging.md section 21). */
const handlePresenceKey = async (request: Request, env: Env): Promise<Response> => {
  const auth = request.headers.get("authorization") ?? ""
  const authenticated = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!authenticated?.user) return Response.json({ error: { code: "auth.unauthenticated", message: "install token required" } }, { status: 401 })
  if (authenticated.install_kind === "vm") return Response.json({ ok: false, error: { code: "auth.forbidden", message: "a VM install has no presence key" } }, { status: 403 })
  const gate = await ssoGate(env, authenticated).catch(() => null)
  if (!gate) return gateUnreachable("ssoGate")
  if (gate.refusal) return Response.json({ ok: false, error: gate.refusal }, { status: 403 })
  const { stack_session: _session, email_domain: _domain, ...principal } = gate.principal
  const user = authenticated.user
  const body = (await request.json().catch(() => null)) as PresenceKeyBody | null
  if (!body) return Response.json({ error: { code: "validation.invalid", message: "JSON body required" } }, { status: 400 })
  const stub = env.USER_DO.get(env.USER_DO.idFromName(user)) as unknown as { registerPresenceKey(e: string, p: unknown, b: PresenceKeyBody): Promise<unknown> }
  const r = (await stub.registerPresenceKey(user, principal, body)) as { error?: { code: string; message: string }; frames?: Array<{ t: string; value?: unknown; code?: string; message?: string }> }
  if (r.error) return Response.json({ ok: false, error: r.error }, { status: r.error.code.startsWith("auth.") ? 403 : 400 })
  const reply = r.frames?.find((f) => f.t === "result" || f.t === "reject")
  if (reply?.t !== "result") return Response.json({ ok: false, error: { code: reply?.code ?? "owner.unreachable", message: reply?.message ?? "no reply" } }, { status: 400 })
  return Response.json({ ok: true, value: reply.value })
}

/** The projection compare's cron expression (wrangler.jsonc staging and development triggers). */
const PROJECTION_COMPARE_CRON = "*/15 * * * *"

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    // The Cloud VM's bind agent (state-placement.md 5.8 item 2): the one-time bind token is the credential.
    if (url.pathname === "/v1/cloud/bind" && request.method === "POST") return handleCloudBind(request, env)
    if (url.pathname === "/v1/cloud/keyset") return handleCloudKeyset(request, env)
    const m = url.pathname.match(/^\/v1\/wire\/(user|team|feed|cloud)$/)
    if (m && request.headers.get("Upgrade") === "websocket") return wire(request, env, m[1]!)
    // Home (E5): one socket per conversation; the ConversationDO admits current participants only.
    const conv = url.pathname.match(/^\/v1\/wire\/conv\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})$/)
    if (conv && request.headers.get("Upgrade") === "websocket") return wire(request, env, "conv", conv[1]!)
    // A chief's wake queue (mux:<agent>): the chief's agent token or its owner; install_kind is resolved.
    const mux = url.pathname.match(/^\/v1\/wire\/mux\/(agent_[A-Za-z0-9_.-]{1,64})$/)
    if (mux && request.headers.get("Upgrade") === "websocket") return wire(request, env, "mux", mux[1]!)
    // Home invite links: anonymous; the card answers only for open invites, the preview only with the secret.
    const card = url.pathname.match(/^\/v1\/invites\/card\/([dg][0-9A-HJKMNP-TV-Z]{26})$/)
    if (card && request.method === "GET") return handleInviteCard(env, card[1]!)
    if (url.pathname === "/v1/invites/preview") return handleInvitePreview(request, env)
    if (url.pathname === "/v1/presence-key" && request.method === "POST") return handlePresenceKey(request, env)
    // Home attachments (home-attachments.ts): intent, commit and URL mint need a bearer; the slot and the signed URL are the credential.
    if (url.pathname === "/v1/home/attachments/intent" && request.method === "POST") return handleAttachmentIntent(request, env)
    if (url.pathname === "/v1/home/attachments/commit" && request.method === "POST") return handleAttachmentCommit(request, env)
    if (url.pathname === "/v1/home/attachments/url" && request.method === "POST") return handleAttachmentUrl(request, env)
    const upload = url.pathname.match(/^\/v1\/home\/attachments\/upload\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([A-Za-z0-9_.-]{1,256})$/)
    if (upload && request.method === "PUT") return handleAttachmentUpload(request, env, upload[1]!, upload[2]!)
    const derivedPut = url.pathname.match(/^\/v1\/home\/attachments\/(poster|preview)\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([A-Za-z0-9_.-]{1,256})$/)
    if (derivedPut && request.method === "PUT") return handleAttachmentDerived(request, env, derivedPut[1] as "poster" | "preview", derivedPut[2]!, derivedPut[3]!)
    const file = url.pathname.match(/^\/v1\/home\/attachments\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([0-9a-f]{32})$/)
    if (file && (request.method === "GET" || request.method === "HEAD")) return handleAttachmentDownload(request, env, file[1]!, file[2]!)
    // Invite texts (stage C part 2): the hosted contact card and SendBlue status webhooks.
    if (url.pathname === CARD_PATH && request.method === "GET") return handleContactCard(env)
    if (url.pathname === "/v1/hooks/sendblue") return handleSendblueHook(request, env)
    if (url.pathname === "/v1/admin/outbox/replay") return handleOutboxReplay(request, env)
    if (url.pathname === "/v1/admin/cloud/abandoned/clear") return handleCloudAbandonedClear(request, env)
    if (url.pathname.startsWith("/v1/admin/team-vm/")) return handleTeamVmAdmin(request, env)
    // Webhook ingress: no bearer; each route verifies its own signature before any DO call.
    const hook = url.pathname.match(/^\/v1\/hooks\/automation\/([^/]+)\/([^/]+)$/)
    if (hook) return handleAutomationHook(request, env, hook[1]!, hook[2]!)
    if (url.pathname === "/v1/sso/discover") return handleSsoDiscover(request, env)
    // cmux server pairing: no account on the server side; each route verifies its own proof.
    if (url.pathname === "/v1/pair/begin") return handlePairBegin(request, env)
    if (url.pathname === "/v1/pair/wait") return handlePairWait(request, env)
    if (url.pathname === "/v1/sso/start") return handleSsoStart(request, env)
    const ssoCallbackPath = url.pathname.match(/^\/v1\/sso\/callback\/([^/]+)$/)
    if (ssoCallbackPath) return handleSsoCallback(request, env, ssoCallbackPath[1]!)
    if (url.pathname === "/v1/sso/redeem") return handleSsoRedeem(request, env)
    // Google push receivers: staging and development only until the backend lead reviews them for production.
    if (env.ENVIRONMENT !== "production" && url.pathname === "/v1/hooks/google/pubsub") return handleGooglePubsub(request, env)
    const providerHook = url.pathname.match(/^\/v1\/hooks\/(github|slack|linear)$/)
    if (providerHook) return handleProviderHook(request, env, providerHook[1] as "github" | "slack" | "linear")
    return apiHandler(request)
  },
  // Cron (wrangler triggers): the feed text sweep (feed-sweep.ts), and every 15 minutes the
  // Postgres/MySQL projection compare while the MySQL shadow runs (projection-compare-cron.ts).
  // Awaited, not waitUntil: the run gets the cron limit, and a throw shows as a failed run.
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    if (controller.cron === PROJECTION_COMPARE_CRON) return (await import("./projection-compare-cron.ts")).compareFromEnv(env)
    const report = await sweepFeedText(sweepDeps(env))
    console.log(JSON.stringify({ msg: "feed.sweep", ...report }))
  }
} satisfies ExportedHandler<Env>
