import { env as workerEnv } from "cloudflare:workers"
import type { OwnerFrame, Principal, RejectFrame, ResultFrame, SettledFrame } from "@cmux/ownership"
import {
  Authorization,
  BadRequest,
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
import { authenticate, mintAccessToken, publicJwks } from "./auth.ts"
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
const teamStub = (team: string) => env.TEAM_DO.get(env.TEAM_DO.idFromName(team))

const unreachable = (e: unknown) => new OwnerUnreachable({ code: "owner.unreachable", message: String(e), retryable: true })

const submitTo = (owner: string, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string; origin?: string; expected_revision?: string }) =>
  Effect.tryPromise({
    try: (): Promise<SubmitResult> => {
      const f = { t: "op" as const, ...frame } as Parameters<ReturnType<typeof userStub>["submit"]>[2]
      return rpc<SubmitResult>(owner === "cloud:UserDO" ? userStub(principal.user!).submit(principal.user!, principal, f) : teamStub(principal.team!).submit(principal.team!, principal, f))
    },
    catch: unreachable
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
        return { install: payload.install, nonce: r.nonce, expires_at: r.expires_at, message_prefix: `cmux-auth-v1\n${env.ENVIRONMENT}\n${payload.install}\n` }
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
          yield* submitTo("cloud:TeamDO", principal, {
            op: "team.ensure_personal",
            params: {},
            idempotency_key: `ensure-personal:${principal.display_name ?? ""}:${principal.email ?? ""}`,
            origin: "cli"
          })
        }
        return response
      })
    )
    .handle("read", ({ payload }) =>
      Effect.gen(function* () {
        const principal = toPrincipal(yield* CurrentPrincipal)
        const def = cloudOpByName.get(payload.op)
        if (!def || def.class !== "read") return yield* new BadRequest({ code: "validation.invalid", message: `unknown read ${payload.op}` })
        const r = yield* Effect.tryPromise({
          try: () =>
            rpc<ReadResult>(
              def.owner === "cloud:UserDO"
                ? userStub(principal.user!).readOp(principal.user!, principal, payload.op, payload.params)
                : teamStub(principal.team!).readOp(principal.team!, principal, payload.op, payload.params)
            ),
          catch: unreachable
        })
        if (!r.ok) return yield* new Forbidden({ code: "auth.forbidden", message: r.message })
        return { op: payload.op, value: r.value, stream: def.owner === "cloud:UserDO" ? `user:${principal.user}` : `team:${principal.team}`, revision: r.revision }
      })
    )
    .handle("debug", () =>
      Effect.gen(function* () {
        const principal = yield* CurrentPrincipal
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
