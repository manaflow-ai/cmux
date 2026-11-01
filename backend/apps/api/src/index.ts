import { isMachineInstallKind } from "./machine-installs.ts"
import { authenticate } from "./auth.ts"
import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { apiHandler } from "./http.ts"
import { handleAutomationHook } from "./ingress/automation-hook.ts"
import { handleProviderHook } from "./ingress/provider-hook.ts"
import { handleGooglePubsub } from "./ingress/google-hooks.ts"
import { handleSsoDiscover } from "./sso-discover.ts"
import { handleStackWebhook, STACK_WEBHOOK_PATH } from "./stack-webhook.ts"
import { principalForOwner, selectTeam, TEAM_SUBPROTOCOL_PREFIX } from "./team-select.ts"
import { forwardHeaders, handleWireTicket, spendTicketAtEntry, wireCredential, wireUnauthenticated, type SpentTicket, type WireScope } from "./wire-ticket.ts"

/** The owner each wire scope reaches (principalForOwner). */
const WIRE_OWNER: Readonly<Record<string, string>> = { team: "cloud:TeamDO", feed: "cloud:FeedDO", cloud: "cloud:CloudDO", conv: "cloud:ConversationDO", mux: "cloud:MuxDO" }
import { handleInviteCard, handleInvitePreview } from "./home-routes.ts"
import { handleAttachmentCommit, handleAttachmentDownload, handleAttachmentIntent, handleAttachmentDerived, handleAttachmentDirectPart, handleAttachmentMultipartComplete, handleAttachmentMultipartPart, handleAttachmentUpload, handleAttachmentUrl } from "./home-attachments.ts"
import { CARD_PATH, handleContactCard, handleSendblueHook } from "./home-text.ts"
import { GROUP_PAGE_ANY, GROUP_PAGE_PATH, groupLinkPage } from "./group-link-page.ts"
import { handleOutboxReplay } from "./admin-outbox.ts"
import { handleCloudAbandonedClear } from "./cloud-admin.ts"
import { handleTeamVmAdmin } from "./team-vm-admin.ts"
import { handleTeamVmExport } from "./team-vm-export-route.ts"
import { signInRules, ssoGate, versionRefusal } from "./policy-gate.ts"
import type { PresenceKeyBody } from "./user-do.ts"
import { handlePairBegin, handlePairWait } from "./pair-routes.ts"
import { handleSsoCallback, handleSsoRedeem, handleSsoStart } from "./sso-routes.ts"
import { sweepDeps, sweepFeedText } from "./feed-sweep.ts"
import { GITHUB_TOKEN_PATH, handleGithubToken } from "./integrations/github-token-route.ts"
import { platformForward } from "./platform-forward.ts"

export { AccountIndexDO } from "./account-index-do.ts"
// Named entrypoint for service bindings only (the platform Worker's environment setups); no HTTP route reaches it.
export { PlatformMachines } from "./platform-machines.ts"
export { AgentGateway } from "./agent-gateway.ts"
export { HandoffDO } from "./handoffs/handoff-do.ts"
export { HandoffIndexDO } from "./handoffs/index-do.ts"
import { handleHandoffs, HANDOFFS_PATH } from "./handoffs/routes.ts"
export { AddressDO } from "./address-do.ts"
export { ConversationDO } from "./conversation-do.ts"
export { MuxDO } from "./mux-do.ts"
export { ChiefBrainDO } from "./chief-brain/brain-do.ts"
export { OpencodeBrainDO } from "./chief-brain-opencode/brain-do.ts"
export { ChiefDurableDO } from "./chief-durable/durable-do.ts"
import { CHIEF_BRAIN_PATH, handleChiefBrain } from "./chief-brain/routes.ts"
import { GATEWAY_PATH, handleModelGateway } from "./model-gateway/http.ts"
import { FAULT_PATH, handleFault } from "./chief-fault.ts"
import { CC_NOTES_PATH, handleCcNotes } from "./chief-brain-cc/routes.ts"
import { durableOn } from "./mux-wake-delivery.ts"
import { handleBrainImpl, handleOpencodeHost, handleOpencodeRuns, OPENCODE_HOST_PATH, OPENCODE_IMPL_PATH, opencodeOn } from "./chief-brain-opencode/routes.ts"
export { DomainDO } from "./domain-do.ts"
export { PairingDO } from "./pairing-do.ts"
export { HostDO } from "./host-do.ts"
export { HandDO } from "./hand-do.ts"
import { HAND_PATH, handleHands } from "./hand-routes.ts"
export { TeamVmDO } from "./team-vm-do.ts"
export { CloudDO } from "./cloud-do.ts"
export { WireTicketDO } from "./wire-ticket.ts"
export { TrajectoryDO } from "./cloud-trajectory-store.ts"
import { handleCloudBind, handleCloudKeyset } from "./cloud-link.ts"
import { ACPMUX_PATH, handleCloudAcpmux } from "./cloud-acpmux.ts"
import { handleCloudTrajectory, TRAJECTORY_PATH, type TrajectoryAction } from "./cloud-trajectory.ts"
import { CLIENT_SESSION_PATH, handleCloudClientSession } from "./cloud-client-session.ts"
import { GUEST_PATH, handleCloudMachineGuest } from "./cloud-machine-guest.ts"
import { BILLING_LEVELS_PATH, BILLING_SYNC_PATH, handleBillingLevels, handleBillingSync } from "./billing-levels.ts"
import { BILLING_TEAM_MODE_PATH, handleBillingTeamMode } from "./billing-team-mode.ts"
import { CREDITS_ADMIN_PATH, handleCreditsAdmin } from "./credits-admin.ts"
import { CREDITS_PATH, CREDITS_WEBHOOK_PATH, handleCredits, handleCreditsWebhook } from "./credits-routes.ts"
import { CHIEF_JOB_HOOK, handleChiefJobHook, handleUpstashChiefJob, UPSTASH_WORKFLOW_PATH } from "./chief-brain-cc/jobs-upstash.ts"
import { handlePlanCheckout, PLAN_PATH } from "./plan-checkout.ts"
import { HOME_HEALTH_CRON, runHomeHealth, sentryFetch } from "./home-health.ts"
export { AutomationRunWorkflow } from "./automation-workflow.ts"
export { AutomationTail } from "./automation-tail.ts"
export { AutomationEgress } from "./automation-egress.ts"
export { ConnectionDO } from "./connection-do.ts"
export { FeedDO } from "./feed-do.ts"
export { SchedulerDO } from "./scheduler-do.ts"
export { TeamDO } from "./team-do.ts"
export { UserDO } from "./user-do.ts"
export { UsageMeterDO } from "./usage-meter-do.ts"
export { SpendGuardDO } from "./inference/spend-guard-do.ts"
export { FreeDeviceDO } from "./inference/free-device-do.ts"

/** The SSO gate could not reach a TeamDO or UserDO: retryable, never a 500 (cx-44j.51). */
const gateUnreachable = (e: unknown) => {
  console.error(JSON.stringify({ msg: "sso gate unreachable", error: String(e) }))
  return Response.json({ error: { code: "owner.unreachable", message: "the sign-in policy could not be checked; retry", retryable: true } }, { status: 503 })
}

/**
 * WebSocket gateway: `GET /v1/wire/{user|team|feed|cloud}` and `/v1/wire/conv/<conversation>` with subprotocol
 * `cmux.wire.v1`. The credential is the Authorization header (native clients), a `ticket.<ticket>`
 * subprotocol from POST /v1/wire/ticket, bound to its scope (browsers); the legacy `bearer.<token>` subprotocol is
 * retired (wire-ticket.ts; invocation logs record every header but Authorization). The Worker
 * authenticates and passes the principal to the owner DO; frames never carry identity.
 */
const wire = async (request: Request, env: Env, spent: SpentTicket | undefined, scope: WireScope, conversation?: string /* or agent for mux */): Promise<Response> => {
  const credential = await wireCredential(request, env, spent, scope)
  if (!credential.ok) return credential.response
  const { principal: authenticatedToken, protocols } = credential
  if (!authenticatedToken?.user || !authenticatedToken.team) return wireUnauthenticated()
  // A session names a shared team with the `team.<id>` subprotocol; TeamDO confirms the membership (team-select.ts).
  const selected = await selectTeam(env, { ...authenticatedToken, user: authenticatedToken.user, team: authenticatedToken.team }, protocols.find((p) => p.startsWith(TEAM_SUBPROTOCOL_PREFIX))?.slice(TEAM_SUBPROTOCOL_PREFIX.length))
  if (!selected.ok) return Response.json({ error: { code: selected.code, message: selected.message } }, { status: selected.code === "owner.unreachable" ? 503 : 403 })
  const authenticated = selected.principal
  // A VM install has no socket (review P1): it reaches only the cloud.vm.* ops.
  if (isMachineInstallKind(authenticated.install_kind)) return Response.json({ error: { code: "auth.forbidden", message: "a VM install has no socket" } }, { status: 403 })
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
  // In a shared team, a role without team.resources (guest, billing) opens no owner's socket but TeamDO's, which checks by grant (review P2-2).
  const granted = scope === "user" ? authed : await principalForOwner(env, WIRE_OWNER[scope] ?? "", authed).catch(() => null)
  if (granted === null) return Response.json({ error: { code: "owner.unreachable", message: "team membership could not be checked; retry" } }, { status: 503 })
  const principal = granted && !("refused" in granted) ? granted : undefined
  if (!principal) return new Response("forbidden", { status: 403 })
  if (scope === "host") return hostReplica(request, env, protocols, principal, conversation!)
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
  const headers = forwardHeaders(request, protocols)
  headers.set("x-cmux-entity", entity)
  headers.set("x-cmux-principal", JSON.stringify(principal))
  const stub = (ns as DurableObjectNamespace).get((ns as DurableObjectNamespace).idFromName(entity))
  return stub.fetch(new Request(request.url, { headers, method: "GET" }))
}

/**
 * `/v1/wire/host/<host>`: the host's read replica in its HostDO (host-replica/wire.ts). TeamDO names
 * the role from the host record: the enrolling install publishes, the owner's other sessions and
 * installs read, anyone else gets 403.
 */
const hostReplica = async (request: Request, env: Env, protocols: ReadonlyArray<string>, principal: Principal, host: string): Promise<Response> => {
  const team = env.TEAM_DO.get(env.TEAM_DO.idFromName(principal.team!)) as unknown as { hostReplicaRole(entity: string, host: string, p: Principal): Promise<"publisher" | "reader" | null> }
  const role = await team.hostReplicaRole(principal.team!, host, principal).catch(() => undefined)
  if (role === undefined) return Response.json({ error: { code: "owner.unreachable", message: "the host directory could not be checked; retry" } }, { status: 503 })
  if (role === null) return new Response("forbidden", { status: 403 })
  const headers = forwardHeaders(request, protocols)
  headers.set("x-cmux-host", host)
  headers.set("x-cmux-replica-role", role)
  headers.set("x-cmux-principal", JSON.stringify(principal))
  return env.HOST_DO.get(env.HOST_DO.idFromName(host)).fetch(new Request(request.url, { headers, method: "GET" }))
}

/** The model router (src/inference): loaded only for its own paths. */
const inference = async (path: string, request: Request, env: Env, ctx: ExecutionContext): Promise<Response> => {
  const r = await import("./inference/route.ts")
  if (path === "/v1/inference/models" && request.method === "GET") return r.handleInferenceModels(env)
  if (path === "/v1/inference/chat/completions" && request.method === "POST") return r.handleChatCompletions(env, request, ctx)
  if (path === "/v1/inference/status" && request.method === "GET") return r.handleInferenceStatus(env, request)
  if (path.startsWith("/v1/inference/free/")) return (await import("./inference/free.ts")).handleFree(env, path, request)
  // Messages API shape: a client's base URL is <origin>/v1/inference (it appends /v1/messages).
  if (path === "/v1/inference/v1/messages" && request.method === "POST") return (await import("./inference/messages.ts")).handleMessages(env, request, ctx)
  if (path === "/v1/inference/v1/messages/count_tokens" && request.method === "POST") return (await import("./inference/messages.ts")).handleCountTokens(env, request)
  return Response.json({ error: { code: "not_found", message: "not found" } }, { status: 404 })
}

/** POST /v1/presence-key with the install's own token (home-messaging.md section 21). */
const handlePresenceKey = async (request: Request, env: Env): Promise<Response> => {
  const auth = request.headers.get("authorization") ?? ""
  const authenticated = await authenticate(env, auth.startsWith("Bearer ") ? auth.slice(7) : undefined)
  if (!authenticated?.user) return Response.json({ error: { code: "auth.unauthenticated", message: "install token required" } }, { status: 401 })
  if (authenticated.install_kind === "vm") return Response.json({ ok: false, error: { code: "auth.forbidden", message: "a VM install has no presence key" } }, { status: 403 })
  const gate = await ssoGate(env, authenticated).catch((e: unknown) => (console.error(JSON.stringify({ msg: "sso gate unreachable", error: String(e) })), null))
  if (!gate) return gateUnreachable("presence key")
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

/** The projection compare's cron expression (wrangler.jsonc triggers of every environment). */
const PROJECTION_COMPARE_CRON = "*/15 * * * *"
/** The hourly full verify of every projected row (projection-compare-full-cron.ts); staging only until the cutover runbook turns it on in production. */
const PROJECTION_COMPARE_FULL_CRON = "7 * * * *"

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url)
    // A wire ticket is spent by the first request that carries it, on any path (wire-ticket.ts).
    const spent = await spendTicketAtEntry(request, env)
    // The platform cutover (platform-forward.ts): a surface in PLATFORM_SURFACES goes to the PLATFORM binding. Unset: nothing changes.
    const forwarded = await platformForward(request, env, url.pathname)
    if (forwarded) return forwarded
    // The Cloud VM's bind agent (state-placement.md 5.8 item 2): the one-time bind token is the credential.
    if (url.pathname === "/v1/cloud/bind" && request.method === "POST") return handleCloudBind(request, env)
    if (url.pathname === "/v1/cloud/keyset") return handleCloudKeyset(request, env)
    // The keyed acpmux start (cx-kvmz): outside the op path, so the key never becomes an op or a log line.
    const acpmux = url.pathname.match(ACPMUX_PATH)
    if (acpmux) return handleCloudAcpmux(request, env, acpmux[1]!, acpmux[2] as "keyed-start" | "person-holds")
    // ACP chat trajectories kept outside the VM (#25584): a log stream, not an op.
    const trajectory = url.pathname.match(TRAJECTORY_PATH)
    if (trajectory) return handleCloudTrajectory(request, env, trajectory[1]!, trajectory[2] as TrajectoryAction)
    // A scoped provider token for one of the caller's machines (cloud-client-session.ts): outside the op path, never logged.
    const clientSession = url.pathname.match(CLIENT_SESSION_PATH)
    if (clientSession) return handleCloudClientSession(request, env, clientSession[1]!)
    // Exec and files on a Cloud machine in classic /api/vm's shapes (cloud-machine-guest.ts): outside the op path, never logged.
    const guest = url.pathname.match(GUEST_PATH)
    if (guest) return handleCloudMachineGuest(request, env, guest[1]!, guest[2] as Parameters<typeof handleCloudMachineGuest>[3])
    // A single-use wire ticket for a browser socket (wire-ticket.ts): Authorization header only.
    if (url.pathname === "/v1/wire/ticket") return handleWireTicket(request, env)
    const m = url.pathname.match(/^\/v1\/wire\/(user|team|feed|cloud)$/)
    if (m && request.headers.get("Upgrade") === "websocket") return wire(request, env, spent, m[1] as WireScope)
    // Home (E5): one socket per conversation; the ConversationDO admits current participants only.
    const conv = url.pathname.match(/^\/v1\/wire\/conv\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})$/)
    if (conv && request.headers.get("Upgrade") === "websocket") return wire(request, env, spent, "conv", conv[1]!)
    // A chief's wake queue (mux:<agent>): the chief's agent token or its owner; install_kind is resolved.
    const mux = url.pathname.match(/^\/v1\/wire\/mux\/(agent_[A-Za-z0-9_.-]{1,64})$/)
    if (mux && request.headers.get("Upgrade") === "websocket") return wire(request, env, spent, "mux", mux[1]!)
    // A host's read replica (object-sync phase 3): its publisher and its owner's readers.
    const hostWire = url.pathname.match(/^\/v1\/wire\/host\/(host_[a-z0-9]{20})$/)
    if (hostWire && request.headers.get("Upgrade") === "websocket") return wire(request, env, spent, "host", hostWire[1]!)
    // Chief hands (hand-routes.ts): the installer, pairing, the hand socket, and the person's hand management.
    if (HAND_PATH.test(url.pathname)) return handleHands(request, env, url.pathname)
    // The model gateway over HTTP (model-gateway/http.ts): run tokens and chief tokens, Anthropic Messages in, events out.
    if (GATEWAY_PATH.test(url.pathname)) return handleModelGateway(request, env, ctx)
    // A chief's Durable Object brain (chief-brain/routes.ts): its owner's settings, and runs for conversation members.
    const chiefBrain = url.pathname.match(CHIEF_BRAIN_PATH)
    // A Chief that runs the opencode brain (chief-brain-opencode/) keeps its runs there.
    const chiefBrainPath = chiefBrain?.[2] === "brain" || chiefBrain?.[2] === "github" || chiefBrain?.[2] === "memory" || chiefBrain?.[2] === "peer" ? chiefBrain[2] : "runs"
    if (chiefBrain && chiefBrainPath === "runs" && (opencodeOn(env) || durableOn(env))) return handleOpencodeRuns(request, env, chiefBrain[1]!, chiefBrain[3], () => handleChiefBrain(request, env, chiefBrain[1]!, "runs", chiefBrain[3]))
    if (chiefBrain) return handleChiefBrain(request, env, chiefBrain[1]!, chiefBrainPath, chiefBrain[3])
    const fault = url.pathname.match(FAULT_PATH)
    if (fault) return handleFault(request, env, fault[1]!)
    const brainImpl = url.pathname.match(OPENCODE_IMPL_PATH)
    if (brainImpl) return handleBrainImpl(request, env, brainImpl[1]!)
    const opencodeHost = url.pathname.match(OPENCODE_HOST_PATH)
    if (opencodeHost) return handleOpencodeHost(request, env, opencodeHost[1]!)
    // The Claude Code route's turn machines stream their turn back here (chief-brain-cc/turn.ts; a per-turn token).
    const ccNotes = url.pathname.match(CC_NOTES_PATH)
    if (ccNotes) return handleCcNotes(request, env, ccNotes[1]!, ccNotes[2]!)
    // Cloud group links (cloud-groups-DESIGN.md): an anonymous hand-off page with no group data.
    if (request.method === "GET" && GROUP_PAGE_ANY.test(url.pathname)) {
      const g = url.pathname.match(GROUP_PAGE_PATH)
      return g ? groupLinkPage(g[1]!) : new Response("not found", { status: 404 })
    }
    // Home invite links: anonymous; the card answers only for open invites, the preview only with the secret.
    const card = url.pathname.match(/^\/v1\/invites\/card\/([dg][0-9A-HJKMNP-TV-Z]{26})$/)
    if (card && request.method === "GET") return handleInviteCard(env, card[1]!)
    if (url.pathname === "/v1/invites/preview") return handleInvitePreview(request, env)
    // Cloud work mode's hand-offs (handoffs/routes.ts): the owner's sessions on cloud machines, and their machines' reports.
    const handoff = url.pathname.match(HANDOFFS_PATH)
    if (handoff) return handleHandoffs(request, env, handoff)
    if (url.pathname === "/v1/presence-key" && request.method === "POST") return handlePresenceKey(request, env)
    if (url.pathname.startsWith("/v1/inference/")) return inference(url.pathname, request, env, ctx)
    // Home attachments (home-attachments.ts): intent, commit and URL mint need a bearer; the slot and the signed URL are the credential.
    if (url.pathname === "/v1/home/attachments/intent" && request.method === "POST") return handleAttachmentIntent(request, env)
    if (url.pathname === "/v1/home/attachments/commit" && request.method === "POST") return handleAttachmentCommit(request, env)
    if (url.pathname === "/v1/home/attachments/multipart/complete" && request.method === "POST") return handleAttachmentMultipartComplete(request, env)
    if (url.pathname === "/v1/home/attachments/url" && request.method === "POST") return handleAttachmentUrl(request, env)
    const upload = url.pathname.match(/^\/v1\/home\/attachments\/upload\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([A-Za-z0-9_.-]{1,256})$/)
    if (upload && request.method === "PUT") return handleAttachmentUpload(request, env, upload[1]!, upload[2]!)
    const multipart = url.pathname.match(/^\/v1\/home\/attachments\/multipart\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([A-Za-z0-9_.-]{1,256})$/)
    if (multipart && request.method === "PUT") return handleAttachmentMultipartPart(request, env, multipart[1]!, multipart[2]!)
    if (multipart && request.method === "POST") return handleAttachmentDirectPart(request, env, multipart[1]!, multipart[2]!)
    const derivedPut = url.pathname.match(/^\/v1\/home\/attachments\/(poster|preview)\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([A-Za-z0-9_.-]{1,256})$/)
    if (derivedPut && request.method === "PUT") return handleAttachmentDerived(request, env, derivedPut[1] as "poster" | "preview", derivedPut[2]!, derivedPut[3]!)
    const file = url.pathname.match(/^\/v1\/home\/attachments\/(conv_(?:dm_)?[0-9A-HJKMNP-TV-Z]{26})\/([0-9a-f]{32})$/)
    if (file && (request.method === "GET" || request.method === "HEAD")) return handleAttachmentDownload(request, env, file[1]!, file[2]!)
    // Invite texts (stage C part 2): the hosted contact card and SendBlue status webhooks.
    if (url.pathname === CARD_PATH && request.method === "GET") return handleContactCard(env)
    if (url.pathname === "/v1/hooks/sendblue") return handleSendblueHook(request, env)
    if (url.pathname === "/v1/admin/outbox/replay") return handleOutboxReplay(request, env)
    // The usage reconcile worker's period levels (service key; cx-y79zh S2).
    if (url.pathname === BILLING_LEVELS_PATH) return handleBillingLevels(request, env)
    if (url.pathname === BILLING_SYNC_PATH) return handleBillingSync(request, env)
    if (url.pathname === BILLING_TEAM_MODE_PATH) return handleBillingTeamMode(request, env)
    // Prepaid Cloud Chief credits: balance and top-ups (credits-routes.ts), the top-up webhook, operator grants.
    const credits = url.pathname.match(CREDITS_PATH)
    if (credits) return handleCredits(request, env, credits[1]?.startsWith("checkout/") && credits[2] ? "checkout/link" : credits[1], credits[2])
    // A Chief's upsell link: a Stripe Checkout page for a plan (plan-checkout.ts, test mode only).
    const planCheckout = url.pathname.match(PLAN_PATH)
    if (planCheckout) return handlePlanCheckout(request, env, planCheckout[1]!)
    // The console's billing page: plan, usage, credits, upgrades (billing-summary.ts, paid-plans-DESIGN.md §3).
    if (url.pathname === "/v1/billing/summary") return (await import("./billing-summary.ts")).handleBillingSummary(request, env)
    if (url.pathname === CREDITS_WEBHOOK_PATH) return handleCreditsWebhook(request, env)
    // Chief jobs on Upstash Workflow: QStash-signed requests only (jobs-upstash.ts).
    if (url.pathname === UPSTASH_WORKFLOW_PATH && request.method === "POST") return handleUpstashChiefJob(request, env)
    if (url.pathname === CREDITS_ADMIN_PATH) return handleCreditsAdmin(request, env)
    if (url.pathname === "/v1/admin/cloud/abandoned/clear") return handleCloudAbandonedClear(request, env)
    if (url.pathname.startsWith("/v1/admin/team-vm/")) return handleTeamVmAdmin(request, env)
    const tvmExport = url.pathname.match(/^\/v1\/team-vm\/export\/(team_[A-Za-z0-9_-]{1,64})\/([0-9a-f]{64})$/)
    if (tvmExport) return handleTeamVmExport(request, env, tvmExport[1]!, tvmExport[2]!)
    // Webhook ingress: no bearer; each route verifies its own signature before any DO call.
    if (url.pathname === STACK_WEBHOOK_PATH) return handleStackWebhook(request, env)
    const hook = url.pathname.match(/^\/v1\/hooks\/automation\/([^/]+)\/([^/]+)$/)
    if (hook) return handleAutomationHook(request, env, hook[1]!, hook[2]!)
    const chiefHook = url.pathname.match(CHIEF_JOB_HOOK)
    if (chiefHook) return handleChiefJobHook(request, env, chiefHook[1]!, chiefHook[2]!)
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
    // GitHub installation tokens for git and gh (integrations/github-token-route.ts): bearer only, never the op path.
    const ghToken = url.pathname.match(GITHUB_TOKEN_PATH)
    if (ghToken) return handleGithubToken(request, env, ghToken[1]!)
    const providerHook = url.pathname.match(/^\/v1\/hooks\/(github|slack|linear)$/)
    if (providerHook) return handleProviderHook(request, env, providerHook[1] as "github" | "slack" | "linear")
    return apiHandler(request)
  },
  // Cron (wrangler triggers): every 5 minutes the Cloud Home health probe (home-health.ts), the feed text sweep (feed-sweep.ts), and every 15 minutes the
  // Postgres/MySQL projection compare while the MySQL shadow runs (projection-compare-cron.ts) and the shadow-read probe (shadow-read-probe.ts),
  // and hourly where configured the full read-only verify of every projected row (projection-compare-full-cron.ts).
  // Awaited, not waitUntil: the run gets the cron limit, and a throw shows as a failed run.
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    // Cloud Home health (home-health.ts): a probe round trip and a Sentry Cron check-in; it never throws.
    if (controller.cron === HOME_HEALTH_CRON) {
      await runHomeHealth(env, { fetcher: sentryFetch })
      return
    }
    // The full Postgres/MySQL verify: its own hourly invocation (a 15-minute CPU limit), read only.
    if (controller.cron === PROJECTION_COMPARE_FULL_CRON) {
      await (await import("./projection-compare-full-cron.ts")).compareFullFromEnv(env, controller.scheduledTime)
      return
    }
    if (controller.cron === PROJECTION_COMPARE_CRON) {
      // The usage sync (cx-y79zh S4) runs beside the projection compare; a failure of one does not stop the other.
      // Never in production yet: production runs this cron for the Vitess dual write, and the usage sync's live switch is its
      // own reviewed change with the live key (plans/cmux-next/usage-billing.md section 10), which removes this condition.
      const usageSync = env.STRIPE_USAGE_KEY && env.ENVIRONMENT !== "production"
      const [compare, usage, probe] = await Promise.allSettled([
        (async () => (await import("./projection-compare-cron.ts")).compareFromEnv(env))(),
        usageSync ? (async () => (await import("./billing-usage-sync.ts")).syncUsage(env))() : Promise.resolve(null),
        // Shadow-read soak traffic (shadow-read-probe.ts): every user id through the feed.users shadow read.
        (async () => (await import("./shadow-read-probe.ts")).shadowReadProbe(env, sweepDeps(env).listUsers))()
      ])
      if (probe.status === "rejected") console.error(JSON.stringify({ msg: "projection.read.probe_failed", error: String(probe.reason).slice(0, 200) }))
      if (usage.status === "rejected") console.error(JSON.stringify({ msg: "billing.usage_sync.run_failed", error: String(usage.reason).slice(0, 200) }))
      if (compare.status === "rejected") throw compare.reason
      return
    }
    const [report, hands] = await Promise.allSettled([sweepFeedText(sweepDeps(env)), (async () => (await import("./hand-sweep.ts")).sweepSandboxVms(env))()])
    if (hands.status === "fulfilled") console.log(JSON.stringify({ msg: "hand.sandbox_sweep", ...hands.value }))
    else console.error(JSON.stringify({ msg: "hand.sandbox_sweep.failed", error: String(hands.reason).slice(0, 200) }))
    if (report.status === "rejected") throw report.reason
    console.log(JSON.stringify({ msg: "feed.sweep", ...report.value }))
  }
} satisfies ExportedHandler<Env>
