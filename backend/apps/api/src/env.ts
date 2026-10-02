import type { TeamDO } from "./team-do.ts"
import type { UserDO } from "./user-do.ts"

export interface Env {
  /** production | staging | development | preview | test */
  readonly ENVIRONMENT: string
  readonly API_VERSION: string
  /** Stack Auth project that signs human session tokens (dev project for staging/development). */
  readonly STACK_PROJECT_ID: string
  /** Test only (ENVIRONMENT=test): a JWKS JSON string that replaces Stack's published keys. */
  readonly STACK_TEST_JWKS?: string
  /** Secret: ES256 private JWK that signs install access tokens. */
  readonly JWT_PRIVATE_JWK: string
  readonly USER_DO: DurableObjectNamespace<UserDO>
  readonly TEAM_DO: DurableObjectNamespace<TeamDO>
  /** PlanetScale `cmux-next` through Hyperdrive (projection writes only). */
  readonly HYPERDRIVE?: Hyperdrive
}
