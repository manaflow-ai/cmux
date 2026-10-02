import { Context, Schema } from "effect"
import { HttpApi, HttpApiEndpoint, HttpApiGroup, HttpApiMiddleware, HttpApiSecurity, OpenApi } from "effect/unstable/httpapi"
import { GrantId, IdempotencyKey, InstallId, Origin, Revision, TeamId, UserId } from "./schemas.ts"

/** The authenticated principal of a request. Never read from a request body. */
export interface CurrentPrincipalShape {
  readonly kind: "session" | "install"
  /** Ledger and single-writer identity: the install id, or `session:<user>`. */
  readonly identity: string
  readonly user: string
  readonly team: string
  readonly install?: string
  readonly grant?: string
  readonly stack_user_id: string
  readonly email?: string | null
  /** Stack asserted the email as verified (claim `email_verified === true`). */
  readonly email_verified?: boolean
  readonly display_name?: string
}
export class CurrentPrincipal extends Context.Service<CurrentPrincipal, CurrentPrincipalShape>()("cmux/CurrentPrincipal") {}

export class Unauthenticated extends Schema.TaggedError<Unauthenticated>()(
  "Unauthenticated",
  { code: Schema.Literal("auth.unauthenticated"), message: Schema.String },
  { httpApiStatus: 401 }
) {}

export class Forbidden extends Schema.TaggedError<Forbidden>()(
  "Forbidden",
  { code: Schema.Literal("auth.forbidden"), message: Schema.String },
  { httpApiStatus: 403 }
) {}

export class BadRequest extends Schema.TaggedError<BadRequest>()(
  "BadRequest",
  { code: Schema.Literals(["validation.invalid", "selector.not_found"]), message: Schema.String },
  { httpApiStatus: 400 }
) {}

export class OwnerUnreachable extends Schema.TaggedError<OwnerUnreachable>()(
  "OwnerUnreachable",
  { code: Schema.Literal("owner.unreachable"), message: Schema.String, retryable: Schema.Boolean },
  { httpApiStatus: 503 }
) {}

/** Bearer: a Stack access token (human session) or a cmux install JWT. */
export class Authorization extends HttpApiMiddleware.Service<Authorization, { provides: CurrentPrincipal; requires: never }>()(
  "cmux/Authorization",
  {
    requiredForClient: true,
    security: { bearer: HttpApiSecurity.bearer },
    error: Unauthenticated
  }
) {}

// ---------------------------------------------------------------- op envelope (wire conventions, backend.md "APIs")

export const OpRequest = Schema.Struct({
  op: Schema.String,
  params: Schema.Unknown,
  idempotency_key: Schema.optionalKey(IdempotencyKey),
  origin: Schema.optionalKey(Origin),
  expected_revision: Schema.optionalKey(Revision)
}).annotate({ identifier: "OpRequest" })

export const OpError = Schema.Struct({
  code: Schema.String,
  message: Schema.String,
  details: Schema.optionalKey(Schema.Unknown),
  retryable: Schema.Boolean
}).annotate({ identifier: "OpError" })

/** Result of one op: either `value` or `error`, always with the settle (write barrier). */
export const OpResponse = Schema.Struct({
  ok: Schema.Boolean,
  op: Schema.String,
  value: Schema.optionalKey(Schema.Unknown),
  error: Schema.optionalKey(OpError),
  transaction: Schema.String,
  idempotency_key: Schema.String,
  revision: Schema.optionalKey(Revision),
  replayed: Schema.Boolean,
  stream: Schema.String,
  sequence: Schema.Int
}).annotate({ identifier: "OpResponse" })

export const ReadResponse = Schema.Struct({
  op: Schema.String,
  value: Schema.Unknown,
  stream: Schema.String,
  revision: Revision
}).annotate({ identifier: "ReadResponse" })

// ---------------------------------------------------------------- groups

export class SystemGroup extends HttpApiGroup.make("system")
  .add(
    HttpApiEndpoint.get("health", "/v1/health", {
      success: Schema.Struct({ ok: Schema.Boolean, environment: Schema.String, version: Schema.String })
    }),
    HttpApiEndpoint.get("jwks", "/.well-known/jwks.json", {
      success: Schema.Struct({ keys: Schema.Array(Schema.Unknown) })
    })
  ) {}

export const ChallengeResponse = Schema.Struct({
  install: InstallId,
  nonce: Schema.String,
  expires_at: Schema.Int,
  /** The install signs `${message_prefix}${nonce}` with its ES256 key (raw r||s, base64url). */
  message_prefix: Schema.String
}).annotate({ identifier: "ChallengeResponse" })

export const TokenResponse = Schema.Struct({
  access_token: Schema.String,
  token_type: Schema.Literal("Bearer"),
  expires_at: Schema.Int,
  user: UserId,
  team: TeamId,
  install: InstallId,
  grant: GrantId
}).annotate({ identifier: "TokenResponse" })

export class AuthGroup extends HttpApiGroup.make("auth")
  .add(
    HttpApiEndpoint.post("challenge", "/v1/auth/challenge", {
      payload: Schema.Struct({ user: UserId, install: InstallId }),
      success: ChallengeResponse,
      error: [BadRequest, Forbidden]
    }),
    HttpApiEndpoint.post("token", "/v1/auth/token", {
      payload: Schema.Struct({ user: UserId, install: InstallId, nonce: Schema.String, signature: Schema.String }),
      success: TokenResponse,
      error: [BadRequest, Forbidden]
    })
  ) {}

export class OpsGroup extends HttpApiGroup.make("ops")
  .add(
    HttpApiEndpoint.post("mutate", "/v1/ops", {
      payload: OpRequest,
      success: OpResponse,
      error: [BadRequest, Forbidden, OwnerUnreachable]
    }),
    HttpApiEndpoint.post("read", "/v1/read", {
      payload: Schema.Struct({ op: Schema.String, params: Schema.Unknown }),
      success: ReadResponse,
      error: [BadRequest, Forbidden, OwnerUnreachable]
    }),
    HttpApiEndpoint.get("debug", "/v1/debug/user", {
      success: Schema.Unknown,
      error: [Forbidden]
    })
  )
  .middleware(Authorization) {}

export class CloudApi extends HttpApi.make("cmux-cloud")
  .add(SystemGroup)
  .add(AuthGroup)
  .add(OpsGroup)
  .annotateMerge(OpenApi.annotations({ title: "cmux Cloud API", version: "0.1.0" })) {}

/** Message the install signs for a token (domain-separated per environment). */
export const challengeMessagePrefix = (environment: string, install: string) => `cmux-auth-v1\n${environment}\n${install}\n`
