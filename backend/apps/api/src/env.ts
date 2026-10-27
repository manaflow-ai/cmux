import type { AddressDO } from "./address-do.ts"
import type { ConversationDO } from "./conversation-do.ts"
import type { MuxDO } from "./mux-do.ts"
import type { ChiefBrainDO } from "./chief-brain/brain-do.ts"
import type { OpencodeBrainDO } from "./chief-brain-opencode/brain-do.ts"
import type { AccountIndexDO } from "./account-index-do.ts"
import type { DomainDO } from "./domain-do.ts"
import type { PairingDO } from "./pairing-do.ts"
import type { HostDO } from "./host-do.ts"
import type { HandDO } from "./hand-do.ts"
import type { WireTicketDO } from "./wire-ticket.ts"
import type { TeamVmDO } from "./team-vm-do.ts"
import type { CloudDO } from "./cloud-do.ts"
import type { ConnectionDO } from "./connection-do.ts"
import type { FeedDO } from "./feed-do.ts"
import type { UsageMeterDO } from "./usage-meter-do.ts"
import type { SpendGuardDO } from "./inference/spend-guard-do.ts"
import type { FreeDeviceDO } from "./inference/free-device-do.ts"
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
  /** GET /v1/cloud/keyset per client IP (namespaces 1161-1163). */
  readonly CLOUD_KEYSET_LIMIT?: RateLimit
  /** POST /v1/wire/ticket per user (namespaces 1191-1193, 60 per minute; wire-ticket.ts). */
  readonly WIRE_TICKET_LIMIT?: RateLimit
  /** Pending cmux server pairings, one object per code (plans/cmux-next/server.md 6.2). */
  readonly PAIRING_DO: DurableObjectNamespace<PairingDO>
  readonly HOST_DO: DurableObjectNamespace<HostDO>
  /** Chief hands (hand-do.ts): one object per installed hand (`h:<hand>`) and one index per owner (`owner:<user>`). */
  readonly HAND_DO: DurableObjectNamespace<HandDO>
  /** "1": Chief hands are on (the /hand and /v1/hands routes, and the brain's hands tools). Off by default; production keeps it off until hands are ready (decision 2026-10-19). */
  readonly HANDS_ENABLED?: string
  /** "1": Cloud requests may reach a `mac` profile hand. Off until the Mac hand trust post (#13742) is confirmed. */
  readonly HANDS_MAC_ENABLED?: string
  /** Comma list of user ids: with HANDS_MAC_ENABLED, only their mac hands take Cloud requests (a scoped test). */
  readonly HANDS_MAC_OWNERS?: string
  /** Base URL of the published acpmux files the hand installer downloads (default https://files.cmux.com/cmux-tui). */
  readonly HAND_RELEASE_BASE?: string
  /** Secret: the hands-only Freestyle key (hand-sandbox.ts is its only reader). Never logged. */
  readonly HAND_FREESTYLE_API_KEY?: string
  /** The mac-hand classifier's model (hand-classify.ts; default claude-haiku-5-5, else the route's model). */
  readonly HAND_CLASSIFIER_MODEL?: string
  /** The classifier's time limit in ms (at most and by default 8000); a test sets it low to prove the timeout path. */
  readonly HAND_CLASSIFIER_TIMEOUT_MS?: string
  /** Minutes a sign-in counts as fresh for replacing a hand presence key (hand-presence.ts; default 10). */
  readonly HAND_PRESENCE_FRESH_MINUTES?: string
  /** Most live sandbox hands one owner may have (default 3). */
  readonly HAND_SANDBOX_MAX?: string
  /** Freestyle snapshot (slug) for Chief sandboxes with a hand (hand-sandbox.ts); baked by scripts/bake-hand-sandbox.ts; unset: no sandbox creation. */
  readonly HAND_SANDBOX_SNAPSHOT?: string
  /** The cmux-tui v2 tree key whose published acpmux the installer installs (wins over HAND_RELEASE_COMMIT). */
  readonly HAND_RELEASE_TREE?: string
  /** The cmux-tui commit whose acpmux the installer installs (its manifest.json lists the SHA-256 of each file). */
  readonly HAND_RELEASE_COMMIT?: string
  /** Single-use wire tickets for browser sockets, 256 shards (wire-ticket.ts). */
  readonly WIRE_TICKET_DO: DurableObjectNamespace<WireTicketDO>
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
  /** Var: "1" turns on the team VM bind (vm-image.md 6b; development and staging until the backend lead's review). */
  readonly TEAM_VM_BIND_ENABLED?: string
  /** Var: provider slug prefix of NEW team VMs; staging must start with `cmuxnp-stg-`, other non-production envs with `cmuxnp-dev-` (FREESTYLE-NAMES). */
  readonly TEAM_VM_SLUG_PREFIX?: string
  /** Test only: `fake` selects the in-object fake provider when ENVIRONMENT=test. */
  readonly TEAM_VM_DRIVER?: string
  /** Operator opt-in for NEW intents only. Existing ledger rows retain their transport. */
  readonly TEAM_VM_TRANSPORT?: string
  readonly TEAM_VM_API_ORIGIN?: string
  readonly TEAM_VM_API_SERVICE_KEY?: string
  readonly TEAM_VM_API_IMAGE?: string
  readonly TEAM_VM_API_IMAGE_REVISION?: string
  /** One CloudDO per team: Cloud machines, the provider-call ledger and plan checks (state-placement.md 5). */
  readonly CLOUD_DO: DurableObjectNamespace<CloudDO>
  /**
   * Secret: the cmux-next Cloud Freestyle key (state-placement.md 5.3), never FREESTYLE_API_KEY (the team VM lane's).
   * Never logged. Without it, or without CLOUD_FREESTYLE_SNAPSHOT, create and delete answer cloud.provider.unavailable.
   */
  readonly CLOUD_FREESTYLE_API_KEY?: string
  /** Operator opt-in for new Cloud machines only. Existing rows keep their recorded transport. */
  readonly CLOUD_VM_TRANSPORT?: string
  readonly CLOUD_VM_API_ORIGIN?: string
  /** Service credential stays in this Worker; never returned or stored with a machine. */
  readonly CLOUD_VM_API_SERVICE_KEY?: string
  readonly CLOUD_VM_API_IMAGE?: string
  readonly CLOUD_VM_API_IMAGE_REVISION?: string
  /** The https API origin written into each VM's bind file (the image's bind agent calls it). */
  readonly CLOUD_API_ORIGIN?: string
  /**
   * `upstash` runs new Chief jobs (`chief-auto`) on Upstash Workflow (chief-brain-cc/jobs-upstash.ts): the
   * records in each team's `<team>/chief-jobs` brain object, a QStash schedule per cron job, a workflow run
   * per fire, and webhook and provider-event (CI failed) triggers. Anything else (the default) keeps them on
   * the SchedulerDO. Needs all four settings below; with any missing, jobs stay on the SchedulerDO. Jobs made
   * on the SchedulerDO keep running there either way.
   */
  readonly CHIEF_JOBS_ENGINE?: string
  /** This Worker's public URL of POST /v1/hooks/upstash/chief-job (where QStash delivers each fire). */
  readonly CHIEF_JOBS_WORKFLOW_URL?: string
  /** Secret: the QStash token of the cmux Upstash account. */
  readonly QSTASH_TOKEN?: string
  /** Optional QStash API origin (a regional or local QStash). */
  readonly QSTASH_URL?: string
  /** Secrets: QStash's request signing keys; every workflow request is verified with them. */
  readonly QSTASH_CURRENT_SIGNING_KEY?: string
  readonly QSTASH_NEXT_SIGNING_KEY?: string
  /** Secret: the operator key for /v1/admin/cloud/abandoned/clear (also needs a person's session token). */
  readonly CLOUD_ADMIN_KEY?: string
  /** Comma-separated user ids who may use the Cloud admin routes (with CLOUD_ADMIN_KEY and their own verified session). */
  readonly CLOUD_ADMIN_USERS?: string
  readonly CLOUD_FREESTYLE_API_URL?: string
  /** Var: the image every Cloud machine boots from; must start with cmuxnp-<env>-vmimg- (CLOUD-DEV-SNAPSHOT). */
  readonly CLOUD_FREESTYLE_SNAPSHOT?: string
  /** Var: provider name prefix; must equal this environment's (cmuxnp-dev-cld-, cmuxnp-stg-cld-, cmuxnp-prod-cld-; FREESTYLE-NAMES) or the provider is off. */
  readonly CLOUD_NAME_PREFIX?: string
  /** Var (development only): the public coderouter host the coderouter.cmux.internal edge rule forwards to (cloud-coderouter-edge.ts); unset = no rule. */
  readonly CLOUD_CODEROUTER_EDGE_HOST?: string
  /** Var: comma-separated team ids that get the stub plan and provider calls outside production (P1-1); unset = nobody. */
  readonly CLOUD_ALLOWED_TEAMS?: string
  /** Var: "on" = Cloud machine limits follow the team's paid plan (cloud-entitlements.ts); anything else = off (stub plan only). Production stays off until go-live. */
  readonly CLOUD_PLAN_ENTITLEMENTS?: string
  /**
   * Secret: link-token signing keys (LINK-TOKEN-FORMAT) as JSON {active: kid, keys: {kid: private Ed25519 JWK}}, at most 2 kids.
   * Per environment; never logged, never in a response, error, event or storage. Without it bind and link_token refuse.
   */
  readonly CLOUD_LINK_SIGNING_KEYS?: string
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
  /** Service key of the usage reconcile worker for POST /v1/internal/billing/levels (billing-levels.ts); the route is absent without it. */
  readonly BILLING_LEVELS_KEY?: string
  /** Payment service key of the usage sync (billing-usage-sync.ts). Test mode only in this phase: a live key is refused. */
  readonly STRIPE_USAGE_KEY?: string
  /** Prepaid Cloud Chief credits (credits.ts): the top-up key (test mode only; default STRIPE_USAGE_KEY) and the top-up webhook's signing secret. */
  readonly STRIPE_CREDITS_KEY?: string
  readonly STRIPE_CREDITS_WEBHOOK_SECRET?: string
  /** Credits price = provider cost x this margin (default 1, pass-through; 1..10). */
  readonly CHIEF_CREDITS_MARGIN?: string
  /** The least one model call holds, USD (default 0.01): a zero-priced model still needs a positive balance. */
  readonly CHIEF_CREDITS_MIN_RESERVE_USD?: string
  /** "0" turns the credits gate off on development and staging (default on); production ignores it and always enforces. */
  readonly CHIEF_CREDITS_ENFORCE?: string
  /** Top-up amounts a person may pick, comma list of whole USD (default 10,20,50,100). */
  readonly CHIEF_CREDITS_TOPUP_USD?: string
  /** Optional payment-service product id for the top-up line (else an inline "cmux Cloud credits" line). */
  readonly CHIEF_CREDITS_PRODUCT?: string
  /** "mysql": the team meters mirror credits to the billing database through PS_MYSQL (credits-mirror.ts); on by default on development; "off" stops it. */
  readonly CREDITS_MIRROR?: string
  /** Dogfood grant (credits-admin.ts): comma list of team_ or user_ ids, the USD per entry, and the round (raise to grant again). */
  readonly CHIEF_CREDITS_DOGFOOD?: string
  readonly CHIEF_CREDITS_DOGFOOD_USD?: string
  readonly CHIEF_CREDITS_DOGFOOD_ROUND?: string
  /** `e2e` on the development Worker only: the usage sync uses the e2e price set (1 USD included; billing-catalog.ts). */
  readonly BILLING_USAGE_PRICE_SET?: string
  /** `1`: a team the usage sync has not seen on a billable subscription stops at its plan's included AI amount (inference/included-stop.ts). */
  readonly USAGE_HARD_STOP_UNBILLED?: string
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
  /** Secret: the Svix endpoint secret (whsec_...) of the Stack team webhook (stack-webhook.ts); unset answers 503. */
  readonly STACK_WEBHOOK_SECRET?: string
  /** Pace of Stack webhook syncs per project, one token per sync (stack-server.ts stackReadPace); namespaces 1201-1203 (cx-f5tk4). */
  readonly STACK_READ_LIMIT?: RateLimit
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
  /** One ChiefBrainDO per chief: the Durable Object brain on pi-durable (chief-brain/brain-do.ts). */
  readonly CHIEF_BRAIN_DO: DurableObjectNamespace<ChiefBrainDO>
  /** "1": MuxDO forwards committed wakes to the chief's brain (each chief's owner still turns it on). Unset in production. */
  readonly CHIEF_BRAIN_ENABLED?: string
  /** The brain's default turn model: "fake" (default) or a Workers AI id `@cf/...` (needs the AI binding). */
  readonly CHIEF_BRAIN_MODEL?: string
  /** The brain's default compactor model (default: CHIEF_BRAIN_MODEL). */
  readonly CHIEF_BRAIN_COMPACTOR_MODEL?: string
  /** A turn's model when Claude's sign-in fails (default "fake"; staging: Workers AI Kimi). */
  readonly CHIEF_BRAIN_FALLBACK_MODEL?: string
  /**
   * Secret (staging only): the X-Stack-Auth value {accessToken, refreshToken} the metered Claude route
   * (/api/claude-david on the Chatmux service) takes. Lawrence's personal chatmux session for now;
   * replace with a scoped service token. Never logged (chief-brain/claude-auth.ts).
   */
  readonly CHIEF_BRAIN_CLAUDE_STACK_AUTH?: string
  /** Owners (user ids, comma separated) whose Chiefs may run on Claude; the route bills one person's account. */
  readonly CHIEF_BRAIN_CLAUDE_OWNERS?: string
  /** Secret: more such owners, changed without a deploy (a demo's test user changes on every reset). */
  readonly CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA?: string
  /** Paid-model turns per owner per UTC day (default 500). */
  readonly CHIEF_BRAIN_CLAUDE_DAILY_TURNS?: string
  /** Paid-model turns of the whole deployment per UTC day (unset: no deployment limit; the per-owner limit applies). */
  readonly CHIEF_BRAIN_CLAUDE_DAILY_TURNS_TOTAL?: string
  /** "1": prune a brain's old pi entries at each turn start (chief-brain/pi-prune.ts). On in staging; off in production until a week of staging soak. */
  readonly CHIEF_BRAIN_PRUNE_PI?: string
  /** Overrides of the Claude route, its sign-in refresh URL and project (tests). */
  readonly CHIEF_BRAIN_CLAUDE_URL?: string
  /** The Claude route's auth: "stack-session" (default), "service-key" (secret CHIEF_BRAIN_CLAUDE_SERVICE_KEY) or "bearer" (secret CHIEF_BRAIN_CLAUDE_TOKEN); model-gateway/routes.ts. */
  readonly CHIEF_BRAIN_CLAUDE_AUTH?: string
  readonly CHIEF_BRAIN_CLAUDE_TOKEN?: string
  readonly CHIEF_BRAIN_CLAUDE_SERVICE_KEY?: string
  /** Spend cap of one per-run gateway token, USD (default 5; model-gateway/run-token.ts). */
  readonly CHIEF_RUN_TOKEN_CAP_USD?: string
  /** Claude names the route serves, comma separated (default "claude-opus-5-5"). */
  readonly CHIEF_BRAIN_CLAUDE_MODELS?: string
  /** "1": send effort + thinking display in the Claude route's Bedrock body ("0" off; default on only for a bearer route). */
  readonly CHIEF_BRAIN_CLAUDE_EFFORT_BODY?: string
  /** The most a turn waits for the compactor before it runs (ms; default 5000, "0": never waits). Staging A/B knob. */
  readonly CHIEF_BRAIN_SETTLE_MS?: string
  /** The most a compaction waits for another call writing its prefix (ms; default 20000, "0": never waits). Staging A/B knob. */
  readonly CHIEF_BRAIN_PREFIX_WAIT_MS?: string
  /** The Claude compactor's effort: "low" or "medium" (default "high"). Staging A/B knob. */
  readonly CHIEF_BRAIN_COMPACT_EFFORT?: string
  /** Prompt cache TTL on the Claude route (default "1h"; "5m" keeps the short default). */
  readonly CHIEF_BRAIN_CACHE_TTL?: string
  /** Secret: OpenRouter key for `openrouter:<id>` Chief models; OPENROUTER_BASE_URL overrides the endpoint. */
  readonly OPENROUTER_API_KEY?: string
  readonly OPENROUTER_BASE_URL?: string
  readonly CHIEF_BRAIN_CLAUDE_REFRESH_URL?: string
  readonly CHIEF_BRAIN_CLAUDE_PROJECT?: string
  /** Turns one chief's brains may start per UTC day (default 300): a spend bound for Workers AI. */
  readonly CHIEF_BRAIN_DAILY_TURNS?: string
  /** Subagents (chief-brain/brain-spawn.ts): most children one Chief runs at once (default 4); the rest wait. */
  readonly CHIEF_SPAWN_MAX?: string
  /** Subagents' model (default: the model of the turn that spawned them). */
  readonly CHIEF_SPAWN_MODEL?: string
  /** Days a subagent's object keeps its storage after its report reached the parent (default 7); its run record then lives in the parent. */
  readonly CHIEF_SPAWN_KEEP_DAYS?: string
  /** First compactor retry delay in ms (default 2 s; exponential backoff with full jitter, cap 5 min). Tests make it small. */
  readonly CHIEF_BRAIN_COMPACT_RETRY_BASE_MS?: string
  /** Test only: the OptChat view budget in bytes (0 = the spec's 128,000). */
  readonly CHIEF_BRAIN_VIEW_BUDGET?: string
  /** One OpencodeBrainDO per chief: the opencode brain (implementation O, chief-brain-opencode/) and its container. Absent: O is off. */
  readonly OPENCODE_BRAIN_DO?: DurableObjectNamespace<OpencodeBrainDO>
  /** "1": a Chief's owner may pick the opencode brain (`brain_impl`); MuxDO sends that Chief's wakes there only. */
  readonly CHIEF_OPENCODE_ENABLED?: string
  /** "1": the deployment has the brain container image bound to OpencodeBrainDO. */
  readonly CHIEF_OPENCODE_CONTAINER?: string
  /** "1": test-only fault hooks (chief-fault.ts) for the crash-mid-turn conformance case; ignored on staging and production. */
  readonly CHIEF_FAULT_HOOKS?: string
  /** The work folder a new sandbox hand starts in (the Chief's continuation names it; default /root/proj). */
  readonly HAND_SANDBOX_WORKDIR?: string
  /**
   * "1": Chiefs of owners on CHIEF_BRAIN_CLAUDE_OWNERS run each turn as Claude Code in a Freestyle VM whose model
   * calls go to the team's sr2 gateway over the tailnet (chief-brain-cc/, personal use, Lawrence 2026-10-20). Needs
   * the two secrets and the snapshot below; off otherwise. Not charged to Cloud credits.
   */
  readonly CHIEF_CC_ENABLED?: string
  /** The chief-cc VM snapshot id (backend/chief-cc/bake.sh). */
  readonly CHIEF_CC_SNAPSHOT?: string
  /** Comma-separated exact owner ids (team_ or user_) whose Chiefs use the Claude Code route; each must also be on CHIEF_BRAIN_CLAUDE_OWNERS. */
  readonly CHIEF_CC_OWNERS?: string
  /** Secret: the Freestyle key of the account that holds CHIEF_CC_SNAPSHOT (no other code reads it). */
  readonly CHIEF_CC_FREESTYLE_API_KEY?: string
  /** Test only: the Freestyle API base for the Claude Code route. */
  readonly CHIEF_CC_FREESTYLE_API_URL?: string
  /** Secret: {"client_id","client_secret"} of the Tailscale OAuth client that mints one-use tag:agent-cloud keys (scope auth_keys). */
  readonly CHIEF_CC_TS_OAUTH?: string
  /** The tag of each turn machine's tailnet node (default tag:agent-cloud); the OAuth client above must own it. Production: tag:lawrence-chief. */
  readonly CHIEF_CC_TS_TAG?: string
  /** Secret: JSON {"path under /home/chief": "content"}, the Chief's tool files (Mac gate and hub tokens) written for the agent user each turn (mode 600). */
  readonly CHIEF_CC_TURN_FILES?: string
  /** Secret: the GitHub token the agent user's gh and git use on each turn machine (fine-grained, the Chief's repos only). */
  readonly CHIEF_CC_GITHUB_TOKEN?: string
  /** The shortest `chief-wake` timer in seconds (chief-brain-cc/wake.ts; default 30, tests 0). */
  readonly CHIEF_CC_WAKE_MIN_SECONDS?: string
  /** The Freestyle plan of CHIEF_CC_FREESTYLE_API_KEY's account (free, hobby or pro; default pro): its per-VM maximums bound the Chief's sandbox sizes. */
  readonly CHIEF_CC_FREESTYLE_PLAN?: string
  /** How many live sandbox VMs each Chief may keep (default 2, at most 10). */
  readonly CHIEF_CC_SANDBOX_CAP?: string
  /** Per-Chief caps over CHIEF_CC_SANDBOX_CAP: "agent_id=N,agent_id=N". */
  readonly CHIEF_CC_SANDBOX_CAPS?: string
  /** The host model gateway's Anthropic Messages base URL for O brains (default: O's own stub route). */
  readonly CHIEF_OPENCODE_GATEWAY_URL?: string
  /** One AddressDO per invited address (HMAC id): suppression, limits, provider sends. */
  readonly ADDRESS_DO: DurableObjectNamespace<AddressDO>
  /** Secret: HMAC key that turns a normalized email or phone into its `addr_` id. */
  readonly HOME_ADDRESS_KEY?: string
  /** Secret: the Sentry project DSN for the Cloud Home health check-ins (home-health.ts); absent = log only. */
  readonly SENTRY_DSN?: string
  /** Secret, staging or development only: `open`, `send` or `read` fails that Cloud Home probe step (the alert drill, home-health.ts); production ignores it. */
  readonly HOME_HEALTH_FAULT?: string
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
  /** Team inviters (user ids or verified emails) whose invites reach any address outside production. */
  readonly HOME_INVITE_ALLOWED_INVITERS?: string
  /** Send switch, fail-closed: only "on" sends invites; unset or any other value sends nothing. */
  readonly HOME_INVITES_SEND?: string
  /** Text channel switch, fail-closed: only "on" sends invite texts through SendBlue (home-text.ts). */
  readonly HOME_INVITES_TEXT?: string
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
  /** Model router (src/inference, plans/cmux-next/model-router.md). One instance "global": daily caps and provider health. */
  readonly SPEND_GUARD_DO: DurableObjectNamespace<SpendGuardDO>
  /** Free tier (src/inference/free.ts): one FreeDeviceDO per App Attest key. */
  readonly FREE_DEVICE_DO: DurableObjectNamespace<FreeDeviceDO>
  /** Per-IP limits of the free tier: every free route, and new device grants. */
  readonly INFERENCE_FREE_IP_LIMIT?: RateLimit
  readonly INFERENCE_FREE_GRANT_LIMIT?: RateLimit
  /** Comma list of "<Team ID>.<bundle id>" App Attest app ids the free tier accepts; unset = free tier refuses. */
  readonly INFERENCE_FREE_APP_IDS?: string
  /** "true" accepts development App Attest keys (dev builds); never in production. */
  readonly INFERENCE_FREE_ATTEST_DEVELOPMENT?: string
  /** Free tier quota per device per UTC day (tokens, default 300000) and requests per minute (default 20). */
  readonly INFERENCE_FREE_DAILY_TOKENS?: string
  readonly INFERENCE_FREE_PER_MINUTE?: string
  /** Apple DeviceCheck: secrets KEY_P8 (PKCS#8 PEM) + KEY_ID, var APPLE_TEAM_ID; "true" = the development endpoint. */
  readonly INFERENCE_DEVICECHECK_KEY_P8?: string
  readonly INFERENCE_DEVICECHECK_KEY_ID?: string
  readonly INFERENCE_DEVICECHECK_DEVELOPMENT?: string
  readonly APPLE_TEAM_ID?: string
  /** Workers AI binding for the model router; absent = the workers-ai provider is not configured. */
  readonly AI?: Ai
  /** Router switch, fail-closed: only "1" serves /v1/inference/chat/completions. */
  readonly INFERENCE_ENABLED?: string
  /** Free tier switch (attested devices without sign-in), fail-closed: only "1". */
  readonly INFERENCE_FREE_ENABLED?: string
  /** Comma list of team ids that may call the router (dev and staging); unset = every signed-in team. */
  readonly INFERENCE_ALLOWED_TEAMS?: string
  /** "1" lets VM installs call the router. */
  readonly INFERENCE_MACHINES_ENABLED?: string
  /** Comma list of providers switched off (kill switch per provider), for example "openrouter,vercel". */
  readonly INFERENCE_DISABLED_PROVIDERS?: string
  /** Hard USD cap per provider per UTC day; INFERENCE_DAILY_CAP_USD_<PROVIDER> overrides one provider. Missing = 0 = refuse. */
  readonly INFERENCE_DAILY_CAP_USD?: string
  readonly INFERENCE_DAILY_CAP_USD_OPENROUTER?: string
  readonly INFERENCE_DAILY_CAP_USD_VERCEL?: string
  readonly INFERENCE_DAILY_CAP_USD_WORKERS_AI?: string
  readonly INFERENCE_DAILY_CAP_USD_FIREWORKS?: string
  readonly INFERENCE_DAILY_CAP_USD_BASETEN?: string
  readonly INFERENCE_DAILY_CAP_USD_DEEPINFRA?: string
  /** Hard USD cap per UTC day for all free-tier requests together. Missing = 0 = refuse. */
  readonly INFERENCE_FREE_DAILY_CAP_USD?: string
  /** Open requests per team (default 4) and per free device (default 1). */
  readonly INFERENCE_MAX_CONCURRENT?: string
  readonly INFERENCE_FREE_MAX_CONCURRENT?: string
  /** Largest max_tokens of a free-tier request (default 4096). */
  readonly INFERENCE_FREE_MAX_TOKENS?: string
  /** Secrets: provider keys. A provider without its key is skipped. */
  readonly INFERENCE_OPENROUTER_KEY?: string
  readonly INFERENCE_VERCEL_GATEWAY_KEY?: string
  readonly INFERENCE_FIREWORKS_KEY?: string
  readonly INFERENCE_BASETEN_KEY?: string
  readonly INFERENCE_DEEPINFRA_KEY?: string
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
