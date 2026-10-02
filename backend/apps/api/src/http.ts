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
  OwnerUnreachable,
  providerOpNames,
  providerReadOpNames,
  Unauthenticated,
  type Connection,
  type CurrentPrincipalShape
} from "@cmux/protocol"
import { Effect, Layer, Redacted } from "effect"
import { HttpRouter, HttpServer } from "effect/unstable/http"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { authenticate, mintAccessToken, publicJwks, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import type { DomainReply } from "./team-domain-external.ts"
import type { ExternalReply } from "./connection-do.ts"
import { automationHookPath, automationHookSecret } from "./ingress/automation-hook.ts"
import { providers } from "./integrations/providers.ts"
import { signState, verifyState } from "./integrations/state.ts"
import type { ReadResult, SubmitResult } from "./owner-do.ts"
import type { RedeemResult } from "./user-do.ts"
import { pairApprove, pairPreview } from "./pair-routes.ts"

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
  stack_user_id: p.stack_user_id,
  ...(p.email !== undefined ? { email: p.email } : {}),
  ...(p.email_verified !== undefined ? { email_verified: p.email_verified } : {}),
  ...(p.display_name ? { display_name: p.display_name } : {})
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
    case "cloud:ConnectionDO":
      return { stub: env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(p.team!)) as unknown as OwnerStub, entity: p.team!, stream: `connections:${p.team}` }
    default:
      throw new Error(`no route for owner ${owner}`)
  }
}

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
  const settled = frames.find((f): f is SettledFrame => f.t === "request-settled")!
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
    stream: settled.stream,
    sequence: settled.sequence
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
          try: () => rpc<RedeemResult>(userStub(payload.user).redeem(payload.user, payload.install, payload.nonce, payload.signature)),
          catch: () => new Forbidden({ code: "auth.forbidden", message: "token mint failed" })
        })
        if (!r.ok) return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
        const { token, expires_at } = yield* Effect.promise(() => mintAccessToken(env, r))
        return { access_token: token, token_type: "Bearer" as const, expires_at, user: r.user, team: r.team, install: r.install, grant: r.grant }
      })
    )
)

const OpsLive = HttpApiBuilder.group(CloudApi, "ops", (handlers) =>
  handlers
    .handle("mutate", ({ payload }) =>
      Effect.gen(function* () {
        const principal = toPrincipal(yield* CurrentPrincipal)
        const def = cloudOpByName.get(payload.op)
        if (!def || def.class !== "mutation") return yield* new BadRequest({ code: "validation.invalid", message: `unknown mutation ${payload.op}` })
        if (!payload.idempotency_key) return yield* new BadRequest({ code: "validation.invalid", message: "mutations require idempotency_key" })
        const frame = {
          op: payload.op,
          params: payload.params ?? {},
          idempotency_key: payload.idempotency_key,
          origin: payload.origin ?? "cli",
          ...(payload.expected_revision ? { expected_revision: payload.expected_revision } : {})
        }
        // Integration ops with external effects run in the ConnectionDO's own ledger (connection-do.ts).
        if (payload.op === "integration.complete" || providerOpNames.has(payload.op)) return yield* externalOp(principal, frame)
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
        // cmux server pairing: several owners in order (UserDO install, TeamDO host, PairingDO), each keyed by the code.
        if (payload.op === "server.pair.approve") {
          return yield* Effect.tryPromise({
            try: () => pairApprove(env, principal, frame, (owner, p, f) => Effect.runPromise(submitTo(owner, p, f))),
            catch: unreachable
          })
        }
        if (payload.op === "integration.connect") {
          const provider = (payload.params as { provider?: string } | null)?.provider
          const impl = provider === "github" || provider === "linear" || provider === "slack" ? providers[provider] : undefined
          if (impl && (!env.INTEGRATIONS_KEK || !env.DASHBOARD_ORIGIN || !impl.configured(env))) {
            return { ok: false, op: payload.op, error: { code: "integration.not_configured", message: `${provider} is not configured on this deployment`, retryable: false }, transaction: "", idempotency_key: frame.idempotency_key, replayed: false, stream: `connections:${principal.team}`, sequence: 0 }
          }
        }
        const { frames } = yield* submitTo(def.owner, principal, frame)
        const response = toResponse(payload.op, frames)
        if (payload.op === "integration.connect" && response.ok) {
          const c = response.value as Connection
          const impl = providers[c.provider]
          const state = yield* Effect.promise(() => signState(env, { conn: c.id, team: c.owner, user: c.created_by, provider: c.provider }))
          const scopes = c.scopes_requested.length > 0 ? c.scopes_requested : impl.defaultScopes
          return { ...response, value: { connection: c, authorize_url: impl.authorizeUrl(env, state, scopes, callbackUrl()) } }
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
        if (providerReadOpNames.has(payload.op)) {
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
        const route = ownerRoute(def.owner, reader)
        const r = yield* Effect.tryPromise({ try: () => rpc<ReadResult>(route.stub.readOp(route.entity, reader, payload.op, payload.params)), catch: unreachable })
        if (!r.ok) {
          if (r.code === "selector.not_found" || r.code === "validation.invalid") return yield* new BadRequest({ code: r.code, message: r.message })
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
          return { op: payload.op, value, stream: route.stream, revision: r.revision }
        }
        return { op: payload.op, value: r.value, stream: route.stream, revision: r.revision }
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
        const p = yield* Effect.promise(() => authenticate(env, Redacted.value(credential)))
        if (!p || !p.user || !p.team) return yield* new Unauthenticated({ code: "auth.unauthenticated", message: "missing or invalid bearer token" })
        const shape: CurrentPrincipalShape = {
          kind: p.kind === "session" ? "session" : "install",
          identity: p.identity,
          user: p.user,
          team: p.team,
          ...(p.install ? { install: p.install } : {}),
          ...(p.grant ? { grant: p.grant } : {}),
          stack_user_id: p.stack_user_id ?? "",
          ...(p.email !== undefined ? { email: p.email } : {}),
          ...(p.email_verified !== undefined ? { email_verified: p.email_verified } : {}),
          ...(p.display_name ? { display_name: p.display_name } : {})
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
