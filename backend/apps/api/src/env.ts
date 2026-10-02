import type { AccountIndexDO } from "./account-index-do.ts"
import type { DomainDO } from "./domain-do.ts"
import type { ConnectionDO } from "./connection-do.ts"
import type { FeedDO } from "./feed-do.ts"
import type { AutomationRunParams, SchedulerDO } from "./scheduler-do.ts"
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
  /** One SchedulerDO per owner team: automation definitions, schedules, recent runs. */
  readonly SCHEDULER_DO: DurableObjectNamespace<SchedulerDO>
  /** One Workflow instance per automation run (instance id = run id). */
  readonly AUTOMATION_RUN: Workflow<AutomationRunParams>
  /** One ConnectionDO per owner team: integration connections; sealed credentials beside them. */
  readonly CONNECTION_DO: DurableObjectNamespace<ConnectionDO>
  /** One FeedDO per user: the feed of notices and requests (plans/cmux-next/feed.md). */
  readonly FEED_DO: DurableObjectNamespace<FeedDO>
  /** One AccountIndexDO per provider account key: which team connections a webhook goes to. */
  readonly ACCOUNT_INDEX_DO: DurableObjectNamespace<AccountIndexDO>
  /** One DomainDO per lowercased email domain: which team verified it (enterprise SSO). */
  readonly DOMAIN_DO: DurableObjectNamespace<DomainDO>
  /** Where provider redirects land (the dashboard's /integrations/callback). */
  readonly DASHBOARD_ORIGIN?: string
  /** Secret: 32-byte base64 key that wraps credential data keys. Integrations refuse to connect without it. */
  readonly INTEGRATIONS_KEK?: string
  /**
   * Secret: the Stack server key for STACK_PROJECT_ID (set on cmux-api-staging and cmux-api by the backend
   * lead). Enterprise SSO creates Stack users and sessions with it; use it only with that project.
   */
  readonly STACK_SECRET_SERVER_KEY?: string
  /** Secrets per provider; a provider without its secrets reports `configured: false`. */
  readonly GITHUB_APP_SLUG?: string
  readonly GITHUB_APP_CLIENT_ID?: string
  readonly GITHUB_APP_CLIENT_SECRET?: string
  /** PKCS#8 PEM (convert GitHub's PKCS#1 download with `openssl pkcs8 -topk8 -nocrypt`). */
  readonly GITHUB_APP_PRIVATE_KEY?: string
  readonly GITHUB_WEBHOOK_SECRET?: string
  readonly LINEAR_CLIENT_ID?: string
  readonly LINEAR_CLIENT_SECRET?: string
  readonly LINEAR_WEBHOOK_SECRET?: string
  readonly SLACK_CLIENT_ID?: string
  readonly SLACK_CLIENT_SECRET?: string
  readonly SLACK_SIGNING_SECRET?: string
  /** PlanetScale `cmux-next` through Hyperdrive (projection writes only). */
  readonly HYPERDRIVE?: Hyperdrive
}
