import { env as workerEnv } from "cloudflare:workers"
import type { OwnerFrame, Principal, RejectFrame, ResultFrame, SettledFrame } from "@cmux/ownership"
import {
  Authorization,
  BadRequest,
  challengeMessagePrefix,
  CloudApi,
  cloudOpByName,
  CurrentPrincipal,
  Forbidden,
  PolicyRefused,
  googleProviderOpNames,
  googleReadOpNames,
  OwnerUnreachable,
  providerOpNames,
  providerReadOpNames,
  Unauthenticated,
  type Connection,
  type CurrentPrincipalShape
} from "@cmux/protocol"
import { Effect, Layer, Redacted } from "effect"
import { HttpRouter, HttpServer, HttpServerRequest } from "effect/unstable/http"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { authenticate, mintAccessToken, publicJwks, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import type { DomainReply } from "./team-domain-external.ts"
import type { ExternalReply } from "./connection-do.ts"
import { automationHookPath, automationHookSecret } from "./ingress/automation-hook.ts"
import { codeRefOf } from "./code-check.ts"
import type { CodeStorageError } from "./code-storage.ts"
import { isProvider, providers, scopesToRequest } from "./integrations/providers.ts"
import { signState, verifyState } from "./integrations/state.ts"
import type { ReadResult, SubmitResult } from "./owner-do.ts"
import type { RedeemResult } from "./user-do.ts"
import { pairApprove, pairPreview } from "./pair-routes.ts"
import { conversationMutate, conversationRead } from "./home-routes.ts"
import { homeSearch, type SearchParams } from "./home-search.ts"
import { signInRules, ssoGate, versionRefusal, withAnySsoSession } from "./policy-gate.ts"
import { forwardIntegrationPolicy, type PolicyFields } from "./integration-policy-forward.ts"

/** DO RPC stubs erase union result types; the DO methods define them. */
const rpc = <T>(p: unknown) => p as Promise<T>
type ChallengeResult = { ok: true; nonce: string; expires_at: number } | { ok: false; message: string }

const env = workerEnv as unknown as Env

const toPrincipal = (p: CurrentPrincipalShape): Principal => ({
  kind: p.kind,
  identity: p.identity,
  user: p.user,
  team: p.team,
  ...(p.install ? { install: p.install } : {}),
  ...(p.grant ? { grant: p.grant } : {}),
  ...(p.agent ? { agent: p.agent } : {}),
  stack_user_id: p.stack_user_id,
  ...(p.email !== undefined ? { email: p.email } : {}),
  ...(p.email_verified !== undefined ? { email_verified: p.email_verified } : {}),
  ...(p.display_name ? { display_name: p.display_name } : {}),
  ...(p.sso_team ? { sso_team: p.sso_team } : {})
})

const userStub = (user: string) => env.USER_DO.get(env.USER_DO.idFromName(user))

/** Shape every owner DO exposes over RPC (OwnerDO). */
interface OwnerStub {
  submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin?: string; expected_revision?: string }): Promise<unknown>
  readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<unknown>
}

/**
 * Owner routing: which object owns an op for this principal. UserDO is keyed by
 * the user; TeamDO and SchedulerDO by the principal's team (phase 1: the
 * personal team from the token; Stack teams will need a TeamDO membership check
 * before routing to a team other than the token's).
 */
const ownerRoute = (owner: string, p: Principal): { stub: OwnerStub; entity: string; stream: string } => {
  switch (owner) {
    case "cloud:UserDO":
      return { stub: userStub(p.user!) as unknown as OwnerStub, entity: p.user!, stream: `user:${p.user}` }
    case "cloud:TeamDO":
      return { stub: env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `team:${p.team}` }
    case "cloud:SchedulerDO":
      return { stub: env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `scheduler:${p.team}` }
    case "cloud:FeedDO":
      return { stub: env.FEED_DO.get(env.FEED_DO.idFromName(p.user!)) as unknown as OwnerStub, entity: p.user!, stream: `feed:${p.user}` }
    case "cloud:UsageMeterDO":
      return { stub: env.USAGE_METER_DO.get(env.USAGE_METER_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `usage:${p.team}` }
    case "cloud:TeamVmDO":
      return { stub: env.TEAM_VM_DO.get(env.TEAM_VM_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `team_vm:${p.team}` }
    case "cloud:CloudDO":
      return { stub: env.CLOUD_DO.get(env.CLOUD_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `cloud:${p.team}` }
    case "cloud:ConnectionDO":
      return { stub: env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `connections:${p.team}` }
    default:
      throw new Error(`no route for owner ${owner}`)
  }
}

/** The stream a read answers from (Home conversations are keyed by params, inbox reads by the user). */
const readStream = (owner: string, op: string, p: Principal, params: unknown) =>
  op.startsWith("inbox.") ? `inbox:${p.user}` : owner === "cloud:ConversationDO" ? `conv:${String((params as { conversation?: unknown } | null)?.conversation ?? "")}` : owner === "cloud:UserDO" ? `user:${p.user}` : ownerRoute(owner, p).stream

/** The CloudDO ops that answer today (skeleton); every other cloud:CloudDO op answers owner.unreachable until it lands. */
const CLOUD_LIVE_OPS: ReadonlySet<string> = new Set(["cloud.machine.list", "cloud.machine.get", "cloud.machine.create", "cloud.machine.rename", "cloud.machine.delete", "cloud.machine.idle_policy.set", "cloud.plan.get", "cloud.machine.connect_info", "cloud.machine.link_token"])
const cloudNotLive = (owner: string, op: string) =>
  owner === "cloud:CloudDO" && !CLOUD_LIVE_OPS.has(op) ? new OwnerUnreachable({ code: "owner.unreachable", message: `${op} is not available yet`, retryable: true }) : undefined

const unreachable = (e: unknown) => new OwnerUnreachable({ code: "owner.unreachable", message: String(e), retryable: true })

/** Principal for a given owner: TeamDO calls carry the grant classes UserDO resolved. */
const principalFor = (owner: string, p: Principal) =>
  owner === "cloud:UserDO"
    ? Effect.succeed(p)
    : Effect.tryPromise({ try: () => withGrantClasses(env, p), catch: unreachable }).pipe(
        Effect.flatMap((q) => (q ? Effect.succeed(q) : Effect.fail(new Forbidden({ code: "auth.forbidden", message: "install revoked or grant invalid" }))))
      )

const submitTo = (owner: string, principalIn: Principal, frame: { op: string; params: unknown; idempotency_key: string; origin?: string; expected_revision?: string }) =>
  Effect.flatMap(principalFor(owner, principalIn), (principal) => Effect.tryPromise({
    try: (): Promise<SubmitResult> => {
      const route = ownerRoute(owner, principal)
      return rpc<SubmitResult>(route.stub.submit(route.entity, principal, { t: "op" as const, ...frame }))
    },
    catch: unreachable
  }))

const callbackUrl = () => `${(env.DASHBOARD_ORIGIN ?? "").replace(/\/$/, "")}/integrations/callback`

/** integration.complete and provider ops: verified state (complete), then the ConnectionDO's external path. */
const externalOp = (principalIn: Principal, frame: { op: string; params: unknown; idempotency_key: string }) =>
  Effect.gen(function* () {
    const principal = yield* principalFor("cloud:ConnectionDO", principalIn)
    let extra: { redirect_uri?: string; state?: { conn: string; provider: string } } = {}
    if (frame.op === "integration.complete") {
      const token = (frame.params as { state?: unknown } | null)?.state
      const st = typeof token === "string" ? yield* Effect.promise(() => verifyState(env, token)) : undefined
      // The state must name this user and team: a link from someone else cannot finish their connection under this session.
      if (!st || st.user !== principal.user || st.team !== principal.team) {
        return { ok: false, op: frame.op, error: { code: "integration.state_invalid", message: "the connection link expired or belongs to someone else", retryable: false }, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `connections:${principal.team}`, sequence: 0 }
      }
      extra = { redirect_uri: callbackUrl(), state: { conn: st.conn, provider: st.provider } }
    }
    const stub = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(principal.team!))
    return yield* Effect.tryPromise({ try: () => rpc<ExternalReply>(stub.external(principal.team!, principal, { ...frame, ...extra })), catch: unreachable })
  })

/** Folds the requester frames (result|reject, request-settled) into one HTTP response. */
const toResponse = (op: string, frames: ReadonlyArray<OwnerFrame>) => {
  const reply = frames.find((f): f is ResultFrame | RejectFrame => f.t === "result" || f.t === "reject")!
  // A request refused before it reached an owner (Worker-side validation) has no settled frame.
  const settled = frames.find((f): f is SettledFrame => f.t === "request-settled")
  return {
    ok: reply.t === "result",
    op,
    ...(reply.t === "result" ? { value: reply.value, revision: reply.revision } : {}),
    ...(reply.t === "reject"
      ? { error: { code: reply.code, message: reply.message, retryable: reply.retryable, ...(reply.details === undefined ? {} : { details: reply.details }) } }
      : {}),
    transaction: reply.tx,
    idempotency_key: reply.idempotency_key,
    replayed: reply.replayed,
    stream: settled?.stream ?? "",
    sequence: settled?.sequence ?? 0
  }
}

const SystemLive = HttpApiBuilder.group(CloudApi, "system", (handlers) =>
  handlers
    .handle("health", () => Effect.succeed({ ok: true, environment: env.ENVIRONMENT, version: env.API_VERSION }))
    .handle("jwks", () => Effect.sync(() => publicJwks(env) as { keys: Array<unknown> }))
)

const AuthLive = HttpApiBuilder.group(CloudApi, "auth", (handlers) =>
  handlers
    .handle("challenge", ({ payload }) =>
      Effect.gen(function* () {
        const r = yield* Effect.tryPromise({ try: () => rpc<ChallengeResult>(userStub(payload.user).challenge(payload.user, payload.install)), catch: () => new Forbidden({ code: "auth.forbidden", message: "challenge failed" }) })
        if (!r.ok) return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
        return { install: payload.install, nonce: r.nonce, expires_at: r.expires_at, message_prefix: challengeMessagePrefix(env.ENVIRONMENT, payload.install) }
      })
    )
    .handle("token", ({ payload }) =>
      Effect.gen(function* () {
        const r = yield* Effect.tryPromise({
          try: () => rpc<RedeemResult>(userStub(payload.user).redeem(payload.user, payload.install, payload.nonce, payload.signature, payload.agent)),
          catch: () => new Forbidden({ code: "auth.forbidden", message: "token mint failed" })
        })
        if (!r.ok) return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
        // Team policy (P17-4): SSO (own team and the email domain's team), updates.minimumVersion against x-cmux-client-version.
        const request = yield* HttpServerRequest.HttpServerRequest
        const rules = yield* Effect.promise(() => signInRules(env, r.team, r.user))
        const minted = { identity: r.install, kind: "install" as const, user: r.user, team: r.team, ...(r.sso_team ? { sso_team: r.sso_team } : {}), ...(r.email_domain ? { email_domain: r.email_domain } : {}) }
        const gate = yield* Effect.promise(() => ssoGate(env, minted))
        const refusedMint = gate.refusal ?? versionRefusal(request.headers["x-cmux-client-version"] ?? null, rules)
        if (refusedMint) return yield* new PolicyRefused(refusedMint)
        const { token, expires_at } = yield* Effect.promise(() => mintAccessToken(env, r))
        return { access_token: token, token_type: "Bearer" as const, expires_at, user: r.user, team: r.team, install: r.install, grant: r.grant }
      })
    )
)

const OpsLive = HttpApiBuilder.group(CloudApi, "ops", (handlers) =>
  handlers
    .handle("mutate", ({ payload }) =>
      Effect.gen(function* () {
        const shape = yield* CurrentPrincipal
        const principal = toPrincipal(shape)
        const def = cloudOpByName.get(payload.op)
        if (!def || def.class !== "mutation") return yield* new BadRequest({ code: "validation.invalid", message: `unknown mutation ${payload.op}` })
        const notLive = cloudNotLive(def.owner, payload.op)
        if (notLive) return yield* notLive
        // LINK-TOKEN-OP: no client key and no replay; a fresh internal key names the request in the audit only.
        if (def.idempotency === "none") {
          if (payload.idempotency_key) return yield* new BadRequest({ code: "validation.invalid", message: `${payload.op} takes no idempotency_key` })
          const p = yield* principalFor(def.owner, principal)
          const request = crypto.randomUUID()
          const stub = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(p.team!)) as unknown as { mintLinkToken(e: string, q: Principal, params: unknown, request: string): Promise<{ ok: boolean; value?: unknown; code?: string; message?: string; details?: unknown }> }
          const r = yield* Effect.tryPromise({ try: () => stub.mintLinkToken(p.team!, p, payload.params ?? {}, request), catch: unreachable })
          const outcome = r.ok ? { value: r.value } : { error: { code: r.code ?? "owner.unreachable", message: r.message ?? "", retryable: r.code === "owner.unreachable", ...(r.details === undefined ? {} : { details: r.details }) } }
          return { ok: r.ok, op: payload.op, ...outcome, transaction: request, idempotency_key: "", replayed: false, stream: "", sequence: 0 }
        }
        if (!payload.idempotency_key) return yield* new BadRequest({ code: "validation.invalid", message: "mutations require idempotency_key" })
        const frame = {
          op: payload.op,
          params: payload.params ?? {},
          idempotency_key: payload.idempotency_key,
          origin: payload.origin ?? "cli",
          ...(payload.expected_revision ? { expected_revision: payload.expected_revision } : {})
        }
        // Integration ops with external effects run in the ConnectionDO's own ledger (connection-do.ts).
        if (payload.op === "integration.complete" || providerOpNames.has(payload.op) || googleProviderOpNames.has(payload.op)) return yield* externalOp(principal, frame)
        // DNS checks and the domain's DomainDO run in TeamDO, outside its reducer (team-domain-external.ts).
        if (payload.op === "domain.verify" || payload.op === "domain.release") {
          const p = yield* principalFor("cloud:TeamDO", principal)
          return yield* Effect.tryPromise({ try: () => rpc<DomainReply>(env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)).domainOp(p.team!, p, frame)), catch: unreachable })
        }
        // The client secret travels only in this request, never in an op's params, event or ledger.
        if (payload.op === "sso.connection.set_secret" || payload.op === "sso.connection.activate") {
          const p = yield* principalFor("cloud:TeamDO", principal)
          return yield* Effect.tryPromise({ try: () => rpc<DomainReply>(env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)).ssoOp(p.team!, p, frame)), catch: unreachable })
        }
        // The team SSH CA signs and seals in TeamDO outside its reducer (team-ssh-ca.ts); keys never enter an op's params.
        if (payload.op === "team_vm.ssh_cert" || payload.op === "team_vm.ssh_cert.challenge" || payload.op === "team_vm.ssh_cert.revoke" || payload.op === "team_vm.ssh_ca.rotate") {
          const p = yield* principalFor("cloud:TeamDO", principal)
          return yield* Effect.tryPromise({ try: () => rpc<DomainReply>(env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)).sshOp(p.team!, p, frame)), catch: unreachable })
        }
        // install.register and server pairing bind the new install to the SSO team whose sign-in created this session (P17-4). The
        // Stack session id only finds that team; owners never receive it (their ledgers record the principal).
        let submitter = principal
        if ((payload.op === "install.register" || payload.op === "server.pair.approve") && shape.stack_session && !principal.sso_team) {
          const stackSession = shape.stack_session
          const found = yield* Effect.promise(() => withAnySsoSession(env, { ...principal, stack_session: stackSession }))
          if (found.sso_team) submitter = { ...principal, sso_team: found.sso_team }
        }
        // cmux server pairing: several owners in order (UserDO install, TeamDO host, PairingDO), each keyed by the code.
        if (payload.op === "server.pair.approve") {
          return yield* Effect.tryPromise({
            try: () => pairApprove(env, submitter, frame, (owner, p, f) => Effect.runPromise(submitTo(owner, p, f))),
            catch: unreachable
          })
        }
        if (payload.op === "integration.connect") {
          const cp = payload.params as { provider?: string; scopes?: unknown } | null
          const provider = cp?.provider
          const impl = isProvider(provider) ? providers[provider] : undefined
          if (impl && (!env.INTEGRATIONS_KEK || !env.DASHBOARD_ORIGIN || !impl.configured(env))) {
            return { ok: false, op: payload.op, error: { code: "integration.not_configured", message: `${provider} is not configured on this deployment`, retryable: false }, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `connections:${principal.team}`, sequence: 0 }
          }
          // A provider may refuse scopes this deployment must not ask for (restricted Gmail scopes before CASA).
          const refused = impl?.refuseScopes?.(env, scopesToRequest(env, impl, Array.isArray(cp?.scopes) ? (cp.scopes as Array<string>) : []))
          if (refused) {
            return { ok: false, op: payload.op, error: { code: "validation.invalid", message: refused, retryable: false }, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `connections:${principal.team}`, sequence: 0 }
          }
        }
        // Ops that pin automation code: the SchedulerDO checks the commit and its bundle in the team's repository first.
        if (def.owner === "cloud:SchedulerDO" && codeRefOf(payload.op, frame.params)) {
          const p = yield* principalFor(def.owner, principal)
          const stub = env.SCHEDULER_DO.get(env.SCHEDULER_DO.idFromName(p.team!))
          const r = yield* Effect.tryPromise({ try: () => rpc<SubmitResult | { refusal: CodeStorageError }>(stub.submitCode(p.team!, p, { t: "op", ...frame })), catch: unreachable })
          if ("refusal" in r) {
            return { ok: false, op: payload.op, error: { code: r.refusal.code, message: r.refusal.message, retryable: r.refusal.retryable }, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `scheduler:${p.team}`, sequence: 0 }
          }
          return toResponse(payload.op, r.frames)
        }
        // The team journal: a durable append in TeamVmDO's side tables, outside the op ledger (the range is its own key).
        if (payload.op === "team_vm.journal.append") {
          const p = yield* principalFor(def.owner, principal)
          const stub = env.TEAM_VM_DO.get(env.TEAM_VM_DO.idFromName(p.team!))
          const r = yield* Effect.tryPromise({ try: () => rpc<SubmitResult>(stub.journalAppend(p.team!, p, { t: "op", ...frame })), catch: unreachable })
          return toResponse(payload.op, r.frames)
        }
        // The team VM: commit the lease, then the DO runs the provider calls and answers with their outcome.
        if (payload.op === "team_vm.ensure_awake") {
          const p = yield* principalFor(def.owner, principal)
          const stub = env.TEAM_VM_DO.get(env.TEAM_VM_DO.idFromName(p.team!))
          const r = yield* Effect.tryPromise({ try: () => rpc<SubmitResult>(stub.ensureAwake(p.team!, p, { t: "op", ...frame })), catch: unreachable })
          return toResponse(payload.op, r.frames)
        }
        // Home: conversations are keyed by the op's params, inbox ops run on UserDO's second stream (home-routes.ts).
        // F3 / P17-6: the old integration policy op is an alias of team.policy.update (TeamPolicy is the single writer).
        if (payload.op === "integration.policy.set") {
          const p = yield* principalFor("cloud:TeamDO", principal)
          const team = env.TEAM_DO.get(env.TEAM_DO.idFromName(p.team!)) as unknown as Parameters<typeof forwardIntegrationPolicy>[0]
          const connections = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(p.team!)) as unknown as Parameters<typeof forwardIntegrationPolicy>[1]
          const res = yield* Effect.tryPromise({ try: () => forwardIntegrationPolicy(team, connections, p.team!, p, (payload.params ?? {}) as PolicyFields, frame.idempotency_key), catch: unreachable })
          return toResponse(payload.op, res.frames as unknown as ReadonlyArray<OwnerFrame>)
        }
        // agents.allowedClasses (P17-4): a chief is the "mux" class.
        if (payload.op === "chief.create") {
          const rules = yield* Effect.promise(() => signInRules(env, principal.team!, principal.user!))
          if (!rules.allowed_classes.includes("mux")) return yield* new PolicyRefused({ code: "policy.denied", message: "your team does not allow chiefs (agents.allowedClasses)" })
        }
        // A chief's MuxDO is keyed by its agent id; the principal carries install_kind (withGrantClasses).
        if (def.owner === "cloud:MuxDO") {
          const p = yield* principalFor(def.owner, principal)
          const agent = (payload.params as { agent?: unknown } | null)?.agent
          if (typeof agent !== "string") return yield* new BadRequest({ code: "validation.invalid", message: `${payload.op} needs an agent` })
          const stub = env.MUX_DO.get(env.MUX_DO.idFromName(agent)) as unknown as OwnerStub
          const mux = yield* Effect.tryPromise({ try: () => rpc<SubmitResult>(stub.submit(agent, p, { t: "op", ...frame })), catch: unreachable })
          return toResponse(payload.op, mux.frames)
        }
        if (def.owner === "cloud:ConversationDO" || payload.op.startsWith("inbox.")) {
          const p = yield* principalFor(def.owner, principal)
          const home = yield* Effect.tryPromise({
            try: (): Promise<SubmitResult> =>
              def.owner === "cloud:ConversationDO"
                ? conversationMutate(env, p, { t: "op", ...frame })
                : rpc<SubmitResult>(userStub(p.user!).submitInbox(p.user!, p, { t: "op", ...frame })),
            catch: unreachable
          })
          return toResponse(payload.op, home.frames)
        }
        const { frames } = yield* submitTo(def.owner, submitter, frame)
        const response = toResponse(payload.op, frames)
        if (payload.op === "integration.connect" && response.ok) {
          const c = response.value as Connection
          const impl = providers[c.provider]
          const state = yield* Effect.promise(() => signState(env, { conn: c.id, team: c.owner, user: c.created_by, provider: c.provider }))
          const scopes = scopesToRequest(env, impl, c.scopes_requested)
          const authorizeUrl = yield* Effect.promise(() => Promise.resolve(impl.authorizeUrl(env, state, scopes, callbackUrl(), c.id)))
          return { ...response, value: { connection: c, authorize_url: authorizeUrl } }
        }
        // A revoked server also loses its install key: TeamDO pushes the revocation to the owner's UserDO now and retries until it lands.
        if (payload.op === "server.revoke" && response.ok) {
          const v = response.value as { host: string; install: string }
          const team = principal.team!
          const flushed = yield* Effect.tryPromise({ try: () => rpc<{ revoked: Array<string> }>(env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).flushServerRevocations(team)), catch: unreachable })
          return { ...response, value: { host: v.host, install_revoked: flushed.revoked.includes(v.install) } }
        }
        // The personal team exists once the user exists (a team of one, identity spec section 2).
        if (payload.op === "user.ensure" && response.ok) {
          // Keyed by the user.ensure transaction: a retry of that request replays, a new ensure re-applies.
          const team = yield* submitTo("cloud:TeamDO", principal, {
            op: "team.ensure_personal",
            params: {},
            idempotency_key: `ensure-personal:${response.transaction}`,
            origin: "cli"
          })
          const teamReply = toResponse("team.ensure_personal", team.frames)
          if (!teamReply.ok) return yield* new OwnerUnreachable({ code: "owner.unreachable", message: `personal team: ${teamReply.error?.message}`, retryable: true })
        }
        return response
      })
    )
    .handle("read", ({ payload }) =>
      Effect.gen(function* () {
        const principal = toPrincipal(yield* CurrentPrincipal)
        const def = cloudOpByName.get(payload.op)
        if (!def || def.class !== "read") return yield* new BadRequest({ code: "validation.invalid", message: `unknown read ${payload.op}` })
        const notLive = cloudNotLive(def.owner, payload.op)
        if (notLive) return yield* notLive
        // Reads honor the op's principal kinds too (automation.webhook.get is session-only: its secret starts runs).
        if (!def.principals.includes(principal.kind === "session" ? "session" : "install")) return yield* new Forbidden({ code: "auth.forbidden", message: `${payload.op} is not allowed for ${principal.kind} principals` })
        if (payload.op === "server.pair.preview") {
          const r = yield* Effect.tryPromise({ try: () => pairPreview(env, principal, payload.params), catch: unreachable })
          if (!r.ok) {
            if (r.code === "auth.forbidden") return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
            return yield* new BadRequest({ code: r.code === "selector.not_found" ? "selector.not_found" : "validation.invalid", message: r.message })
          }
          return { op: payload.op, value: r.value, stream: "pairing", revision: "0" }
        }
        const reader = yield* principalFor(def.owner, principal)
        // Home search reads the PlanetScale projection through the read-only Hyperdrive (home-search.ts).
        if (payload.op === "home.search") {
          const r = yield* Effect.tryPromise({ try: () => homeSearch(env, reader, (payload.params ?? {}) as SearchParams), catch: unreachable })
          if (!r.ok) {
            if (r.code === "auth.forbidden") return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
            if (r.code === "search.unavailable") return yield* new OwnerUnreachable({ code: "owner.unreachable", message: r.message, retryable: true })
            return yield* new BadRequest({ code: "validation.invalid", message: r.message })
          }
          return { op: payload.op, value: r.value, stream: `search:${reader.user}`, revision: "0" }
        }
        if (providerReadOpNames.has(payload.op) || googleReadOpNames.has(payload.op)) {
          const stub = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(reader.team!))
          const pr = yield* Effect.tryPromise({
            try: () => rpc<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>(stub.providerRead(reader.team!, reader, payload.op, payload.params)),
            catch: unreachable
          })
          if (!pr.ok) {
            if (pr.code === "auth.forbidden") return yield* new Forbidden({ code: "auth.forbidden", message: pr.message })
            return yield* new BadRequest({ code: pr.code === "selector.not_found" ? "selector.not_found" : "validation.invalid", message: `${pr.code}: ${pr.message}` })
          }
          return { op: payload.op, value: pr.value, stream: `connections:${reader.team}`, revision: "0" }
        }
        const r = yield* Effect.tryPromise({
          try: (): Promise<ReadResult> => {
            if (def.owner === "cloud:ConversationDO") return conversationRead(env, reader, payload.op, payload.params) as Promise<ReadResult>
            if (payload.op.startsWith("inbox.")) return rpc<ReadResult>(userStub(reader.user!).readInbox(reader.user!, reader, payload.op, (payload.params ?? {}) as Record<string, unknown>))
            const route = ownerRoute(def.owner, reader)
            return rpc<ReadResult>(route.stub.readOp(route.entity, reader, payload.op, payload.params))
          },
          catch: unreachable
        })
        if (!r.ok) {
          if (r.code === "selector.not_found" || r.code === "validation.invalid" || r.code === "cloud.machine.not_found" || r.code === "cloud.machine.not_bound") return yield* new BadRequest({ code: r.code, message: r.message })
          return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
        }
        // A webhook trigger's secret is derived in the Worker, never stored in the DO.
        if (payload.op === "automation.webhook.get") {
          const v = r.value as { owner: string; automation: string; trigger: string }
          const secret = yield* Effect.promise(() => automationHookSecret(env, v.owner, v.trigger))
          const value = {
            automation: v.automation,
            trigger: v.trigger,
            path: automationHookPath(v.owner, v.trigger),
            secret,
            scheme: "x-cmux-signature: v1=hex(HMAC-SHA256(secret, x-cmux-timestamp + '.' + body)); dedupe on timestamp and body; optional x-cmux-delivery label"
          }
          return { op: payload.op, value, stream: readStream(def.owner, payload.op, reader, payload.params), revision: r.revision }
        }
        return { op: payload.op, value: r.value, stream: readStream(def.owner, payload.op, reader, payload.params), revision: r.revision }
      })
    )
    .handle("debug", () =>
      Effect.gen(function* () {
        const principal = yield* CurrentPrincipal
        // Human sessions only: the dump holds the ledger and every install's details.
        if (principal.kind !== "session") return yield* new Forbidden({ code: "auth.forbidden", message: "debug needs a user session" })
        return yield* Effect.tryPromise({ try: () => userStub(principal.user).debug(principal.user), catch: () => new Forbidden({ code: "auth.forbidden", message: "debug failed" }) })
      })
    )
)

const AuthorizationLive = Layer.succeed(Authorization)(
  Authorization.of({
    bearer: (httpEffect, { credential }) =>
      Effect.gen(function* () {
        const authed = yield* Effect.promise(() => authenticate(env, Redacted.value(credential)))
        if (!authed || !authed.user || !authed.team) return yield* new Unauthenticated({ code: "auth.unauthenticated", message: "missing or invalid bearer token" })
        // Team policy (P17-4): the principal's team and the team that owns the user's email domain refuse
        // sessions and installs not from their SSO.
        const gate = yield* Effect.promise(() => ssoGate(env, authed))
        if (gate.refusal) return yield* new PolicyRefused(gate.refusal)
        const p = gate.principal
        const shape: CurrentPrincipalShape = {
          kind: p.kind === "session" ? "session" : "install",
          identity: p.identity,
          user: authed.user,
          team: authed.team,
          ...(p.install ? { install: p.install } : {}),
          ...(p.grant ? { grant: p.grant } : {}),
          ...(p.agent ? { agent: p.agent } : {}),
          stack_user_id: p.stack_user_id ?? "",
          ...(p.email !== undefined ? { email: p.email } : {}),
          ...(p.email_verified !== undefined ? { email_verified: p.email_verified } : {}),
          ...(p.display_name ? { display_name: p.display_name } : {}),
          ...(p.sso_team ? { sso_team: p.sso_team } : {}),
          ...(p.stack_session ? { stack_session: p.stack_session } : {})
        }
        return yield* Effect.provideService(httpEffect, CurrentPrincipal, shape)
      })
  })
)

const ApiLive = HttpApiBuilder.layer(CloudApi, { openapiPath: "/v1/openapi.json" }).pipe(
  Layer.provide([SystemLive, AuthLive, OpsLive]),
  Layer.provide(AuthorizationLive)
)

export const { handler: apiHandler } = HttpRouter.toWebHandler(ApiLive.pipe(Layer.provide(HttpServer.layerServices)))
