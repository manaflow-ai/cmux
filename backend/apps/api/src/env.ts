import type { AddressDO } from "./address-do.ts"
import type { ConversationDO } from "./conversation-do.ts"
import type { MuxDO } from "./mux-do.ts"
import type { AccountIndexDO } from "./account-index-do.ts"
import type { DomainDO } from "./domain-do.ts"
import type { PairingDO } from "./pairing-do.ts"
import type { HostDO } from "./host-do.ts"
import type { TeamVmDO } from "./team-vm-do.ts"
import type { CloudDO } from "./cloud-do.ts"
import type { ConnectionDO } from "./connection-do.ts"
import type { FeedDO } from "./feed-do.ts"
import type { UsageMeterDO } from "./usage-meter-do.ts"
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
  /** Workers rate limit for unauthenticated sign-in discovery (30 per minute per client IP). */
  readonly SSO_DISCOVER_LIMIT?: RateLimit
  /** Pending cmux server pairings, one object per code (plans/cmux-next/server.md 6.2). */
  readonly PAIRING_DO: DurableObjectNamespace<PairingDO>
  readonly HOST_DO: DurableObjectNamespace<HostDO>
  /** One TeamVmDO per team: the team VM record, wake leases, provider calls (plans/cmux-next/team-vm-plan.md S2). */
  readonly TEAM_VM_DO: DurableObjectNamespace<TeamVmDO>
  /**
   * Secret: Freestyle API key for team VMs. Without it (or the two vars below) team_vm.ensure_awake reports team_vm.not_configured.
   * HARD BLOCKER: do not set it in production before the TeamVmDO plan gate lands (plans/cmux-next/team-vm-plan.md 3a).
   * Until then production refuses every provider call with team_vm.plan_gate_missing (PRODUCTION_PLAN_GATE_LANDED).
   */
  readonly FREESTYLE_API_KEY?: string
  readonly FREESTYLE_API_URL?: string
  /** Var: the snapshot team VMs boot from (lane 1's image with the team role). */
  readonly TEAM_VM_SNAPSHOT?: string
  /** Var: provider slug prefix of NEW team VMs; staging must start with `cmuxnp-stg-`, other non-production envs with `cmuxnp-dev-` (FREESTYLE-NAMES). */
  readonly TEAM_VM_SLUG_PREFIX?: string
  /** Test only: `fake` selects the in-object fake provider when ENVIRONMENT=test. */
  readonly TEAM_VM_DRIVER?: string
  /** One CloudDO per team: Cloud machines, the provider-call ledger and plan checks (state-placement.md 5). */
  readonly CLOUD_DO: DurableObjectNamespace<CloudDO>
  /**
   * Secret: the cmux-next Cloud Freestyle key (state-placement.md 5.3), never FREESTYLE_API_KEY (the team VM lane's).
   * Never logged. Without it, or without CLOUD_FREESTYLE_SNAPSHOT, create and delete answer cloud.provider.unavailable.
   */
  readonly CLOUD_FREESTYLE_API_KEY?: string
  readonly CLOUD_FREESTYLE_API_URL?: string
  /** Var: the image every Cloud machine boots from; must start with cmuxnp-<env>-vmimg- (CLOUD-DEV-SNAPSHOT). */
  readonly CLOUD_FREESTYLE_SNAPSHOT?: string
  /** Var: provider name prefix; must equal this environment's (cmuxnp-dev-cld-, cmuxnp-stg-cld-, cmuxnp-prod-cld-; FREESTYLE-NAMES) or the provider is off. */
  readonly CLOUD_NAME_PREFIX?: string
  /** Var: comma-separated team ids that get the stub plan and provider calls outside production (P1-1); unset = nobody. */
  readonly CLOUD_ALLOWED_TEAMS?: string
  /** Per-team limit on cloud.machine.create and delete (namespace 1151-1153). */
  readonly CLOUD_MUTATION_LIMIT?: RateLimit
  /** Test only: `fake` selects the in-object fake Cloud provider when ENVIRONMENT=test. */
  readonly CLOUD_DRIVER?: string
  /** Per-IP limit on unauthenticated pairing begins. */
  readonly PAIR_BEGIN_LIMIT?: RateLimit
  /** Where provider redirects land (the dashboard's /integrations/callback). */
  readonly DASHBOARD_ORIGIN?: string
  /** Secret: 32-byte base64 key that wraps credential data keys. Integrations refuse to connect without it. */
  readonly INTEGRATIONS_KEK?: string
  /**
   * AWS KMS for credential data keys (integrations-plan.md G6). With all four set, new seals wrap the
   * data key with this KMS key; INTEGRATIONS_KEK still opens older rows and derives PKCE keys.
   */
  /** Operator key for POST /v1/admin/outbox/replay (admin-outbox.ts); the route is absent without it. */
  readonly OUTBOX_ADMIN_KEY?: string
  /** Operator key for /v1/admin/team-vm/* (team-vm-admin.ts: registry counts, on-demand prefix report); the routes are absent without it. */
  readonly TEAM_VM_ADMIN_KEY?: string
  readonly INTEGRATIONS_KMS_KEY_ARN?: string
  readonly INTEGRATIONS_KMS_REGION?: string
  /** Secrets: the IAM user's access key, allowed only kms:Encrypt and kms:Decrypt with our encryption context. */
  readonly INTEGRATIONS_KMS_ACCESS_KEY_ID?: string
  readonly INTEGRATIONS_KMS_SECRET_ACCESS_KEY?: string
  /** Earlier KMS key ARNs (comma separated) whose rows stay readable after a key change. */
  readonly INTEGRATIONS_KMS_PREVIOUS_KEY_ARNS?: string
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
  /** Google OAuth client of the integrations Google Cloud project (Gmail and Google Calendar share it). */
  readonly GOOGLE_CLIENT_ID?: string
  /** Secret: that client's secret. */
  readonly GOOGLE_CLIENT_SECRET?: string
  /**
   * `testing` | `internal` | `verified`: this deployment may ask for restricted Gmail scopes
   * (gmail.readonly, gmail.modify). Unset in production until Google's security assessment passes.
   */
  readonly GOOGLE_RESTRICTED_SCOPES?: string
  /** Gmail push: the Pub/Sub topic `projects/<project>/topics/<topic>` that users.watch publishes to; unset = no watches. */
  readonly GOOGLE_PUBSUB_TOPIC?: string
  /** Gmail push: the audience and the service-account email of the push subscription's OIDC token (the Worker route checks both). */
  readonly GOOGLE_PUBSUB_AUDIENCE?: string
  readonly GOOGLE_PUBSUB_SERVICE_ACCOUNT?: string
  /** Test only (ENVIRONMENT=test): a JWKS JSON string that replaces Google's published keys for Pub/Sub tokens. */
  readonly GOOGLE_PUBSUB_TEST_JWKS?: string
  /** Workers rate limit counted only for refused Google push requests (per client IP). */
  readonly GOOGLE_HOOK_FAIL_LIMIT?: RateLimit
  /** Home (plans/cmux-next/home-messaging.md): one ConversationDO per conversation. */
  readonly CONVERSATION_DO: DurableObjectNamespace<ConversationDO>
  /** One MuxDO per chief: its wake queue. */
  readonly MUX_DO: DurableObjectNamespace<MuxDO>
  /** One AddressDO per invited address (HMAC id): suppression, limits, provider sends. */
  readonly ADDRESS_DO: DurableObjectNamespace<AddressDO>
  /** Secret: HMAC key that turns a normalized email or phone into its `addr_` id. */
  readonly HOME_ADDRESS_KEY?: string
  /** Private R2 bucket of Home attachments (objects `home/v1/<conversation>/<sha256>/<upload id>`); no public access. */
  readonly HOME_ATTACHMENTS?: R2Bucket
  /** Secret: HMAC key of attachment upload slots and download URLs (at least 32 characters); unset = attachments off. */
  readonly HOME_ATTACHMENT_KEY?: string
  /** Key id of HOME_ATTACHMENT_KEY, signed into every slot and URL (default "1"). */
  readonly HOME_ATTACHMENT_KEY_ID?: string
  /** Rotation: the previous key and its id; URLs signed with it stay valid until they expire. */
  readonly HOME_ATTACHMENT_KEY_PREVIOUS?: string
  readonly HOME_ATTACHMENT_KEY_PREVIOUS_ID?: string
  /** Presigned PUTs for 32-100 MB files: R2 S3 endpoint (https://<account>.r2.cloudflarestorage.com), bucket and a bucket-scoped token. Unset = large files refused. */
  readonly HOME_ATTACHMENTS_S3_ENDPOINT?: string
  readonly HOME_ATTACHMENTS_S3_BUCKET?: string
  readonly HOME_ATTACHMENTS_S3_ACCESS_KEY_ID?: string
  readonly HOME_ATTACHMENTS_S3_SECRET_ACCESS_KEY?: string
  /** Burst limit per user on attachment intents and download URL mints. */
  readonly HOME_ATTACHMENT_LIMIT?: RateLimit
  /** "<Apple Team ID>.<iOS bundle id>" whose App Attest keys this deployment accepts (presence keys). */
  readonly IOS_APP_ID?: string
  /** "true" accepts App Attest development keys (appattestdevelop); staging and development only. */
  readonly IOS_APP_ATTEST_DEVELOPMENT?: string
  /** Secrets for invite delivery (Resend email, SendBlue SMS and iMessage). */
  readonly RESEND_API_KEY?: string
  readonly SENDBLUE_API_KEY?: string
  readonly SENDBLUE_API_SECRET?: string
  readonly SENDBLUE_FROM_NUMBER?: string
  readonly SENDBLUE_WEBHOOK_SECRET?: string
  /** Header that carries the SendBlue webhook secret (default sb-signing-secret; UNVERIFIED until the first staging webhook). */
  readonly SENDBLUE_WEBHOOK_HEADER?: string
  /** Staging, development and previews only: comma-separated recipients invites may reach; missing = none. */
  readonly HOME_INVITE_ALLOWLIST_EMAILS?: string
  readonly HOME_INVITE_ALLOWLIST_PHONES?: string
  /** Send switch, fail-closed: only "on" sends invites; unset or any other value sends nothing. */
  readonly HOME_INVITES_SEND?: string
  /** Invite email sender, for example "cmux <invites@cmux.dev>" (the domain verified in Resend); unset = no email sends. */
  readonly HOME_INVITE_FROM?: string
  /** This Worker's name from wrangler.jsonc vars (cmux-api in production); with ENVIRONMENT it decides production behavior. */
  readonly WORKER_NAME?: string
  /** Origin of invite links (the dashboard): https://console-staging.cmux.dev or https://console.cmux.dev. */
  readonly HOME_INVITE_ORIGIN?: string
  /** Secrets for owner-decided iPhone pushes (feed.md 7.3); without them pushes are only logged. */
  readonly APNS_KEY_P8?: string
  readonly APNS_KEY_ID?: string
  readonly APNS_TEAM_ID?: string
  /** One UsageMeterDO per team: the automation usage ledger and hard cap (automations-billing.md). */
  readonly USAGE_METER_DO: DurableObjectNamespace<UsageMeterDO>
  /**
   * Hard cap per team per UTC month for automations (USD, decision A18). Staging and development: "25"
   * until Lawrence sets the value (Stripe TEST only). Missing = 0 = no metered run may start.
   */
  readonly AUTOMATION_CAP_CEILING_USD?: string
  /** Worker Loader (Dynamic Workers): Tier 1 code automations (code-run.ts). Absent = code runs fail with body.unsupported. */
  readonly LOADER?: WorkerLoader
  /** code.storage organization for team code repositories (decisions A12, C1); staging and development share one (A2). */
  readonly CODE_STORAGE_ORG?: string
  /** Secret: PKCS#8 PEM of that organization's ES256 key. Code automations refuse to pin without it. */
  readonly CODE_STORAGE_PRIVATE_KEY?: string
  /** PlanetScale `cmux-next` through Hyperdrive (projection writes only). */
  readonly HYPERDRIVE?: Hyperdrive
  /** Read-only role (search-ro, pg_read_all_data) for home.search; never used for writes. */
  readonly HYPERDRIVE_RO?: Hyperdrive
  /** PlanetScale MySQL `cmux-next-vitess` through Hyperdrive, readwriter role (projection writes). */
  readonly PS_MYSQL?: Hyperdrive
  /** PlanetScale MySQL reader role (home.search, directory reads). */
  readonly PS_MYSQL_RO?: Hyperdrive
  /** Projection primary: "postgres" (default) until the verified MySQL cutover, then "mysql". */
  readonly PROJECTION_PRIMARY?: string
  /** Projection shadow during dual write: "mysql" or "postgres"; unset = none. */
  readonly PROJECTION_SHADOW?: string
  /** Where projection reads (home.search, feed sweep) go: "postgres" (default) or "mysql". */
  readonly PROJECTION_READS?: string
}
