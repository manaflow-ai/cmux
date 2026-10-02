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
  Unauthenticated,
  type CurrentPrincipalShape
} from "@cmux/protocol"
import { Effect, Layer, Redacted } from "effect"
import { HttpRouter, HttpServer } from "effect/unstable/http"
import { HttpApiBuilder } from "effect/unstable/httpapi"
import { authenticate, mintAccessToken, publicJwks, withGrantClasses } from "./auth.ts"
import type { Env } from "./env.ts"
import type { ReadResult, SubmitResult } from "./owner-do.ts"
import type { RedeemResult } from "./user-do.ts"

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
        const { frames } = yield* submitTo(def.owner, principal, frame)
        const response = toResponse(payload.op, frames)
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
        const reader = yield* principalFor(def.owner, principal)
        const route = ownerRoute(def.owner, reader)
        const r = yield* Effect.tryPromise({ try: () => rpc<ReadResult>(route.stub.readOp(route.entity, reader, payload.op, payload.params)), catch: unreachable })
        if (!r.ok) {
          if (r.code === "selector.not_found" || r.code === "validation.invalid") return yield* new BadRequest({ code: r.code, message: r.message })
          return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
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
