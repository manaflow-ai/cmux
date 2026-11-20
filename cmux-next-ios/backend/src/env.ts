import type { TeamHub } from "./team-hub.ts"

export interface Env {
  readonly ENVIRONMENT: string
  readonly API_VERSION: string
  /**
   * JSON array of the Stack projects whose users this Worker accepts (see `StackProject` in auth.ts).
   * The first entry is the primary project: rows written before multi-project support belong to it, and
   * STACK_SECRET_SERVER_KEY (when set) is its server key.
   */
  readonly STACK_PROJECTS: string
  readonly TEAM_HUB: DurableObjectNamespace<TeamHub>
  /** Absent in tests: the memory store is used instead. */
  /** PlanetScale MySQL cmux-next-vitess (readwriter) through Hyperdrive; absent in tests (memory store). */
  readonly PS_MYSQL?: Hyperdrive
  /** Optional: the primary project's server key. Membership and invites then use the Stack server API for that project's users. */
  readonly STACK_SECRET_SERVER_KEY?: string
  readonly TURN_KEY_ID?: string
  readonly TURN_KEY_API_TOKEN?: string
  readonly ICE_TTL_SECONDS?: string
  /** APNs (src/push.ts): all three or none. */
  readonly APNS_KEY_P8?: string
  readonly APNS_KEY_ID?: string
  readonly APNS_TEAM_ID?: string
  /** Comma-separated bundle ids a phone may register a push token for. */
  readonly APNS_TOPICS?: string
  /** Workers rate limiting bindings (absent in tests that do not configure them). */
  readonly USER_LIMIT?: RateLimit
  readonly ICE_LIMIT?: RateLimit
  readonly INVITE_LIMIT?: RateLimit
  readonly NOTIFY_LIMIT?: RateLimit
  /** Mailbox replies per user (PROTOCOL.md "Reply mailbox"). */
  readonly MAILBOX_LIMIT?: RateLimit
  /** Team creations per user (they make Stack teams with the server key). */
  readonly TEAM_LIMIT?: RateLimit
  /** Milliseconds before an isolate retries a failed team hub retire (default 10 s; tests set 0). */
  readonly TEAM_HUB_RETIRE_RETRY_MS?: string
  /** Connectivity alerts (src/connectivity-alerts.ts): the one desk that posts them. */
  readonly CONNECTIVITY_ALERT_DESK: DurableObjectNamespace<import("./connectivity-alerts.ts").ConnectivityAlertDesk>
  /** Slack bot token (chat:write) of the app that posts connectivity alerts; unset: alerts are kept, not sent. */
  readonly SLACK_BOT_TOKEN?: string
  /** Slack channel id for the cmux team's real phones. */
  readonly CONNECTIVITY_ALERT_CHANNEL?: string
  /** Slack channel id for simulators and agent accounts; unset: their reports are dropped. */
  readonly CONNECTIVITY_ALERT_TEST_CHANNEL?: string
  /** Extra team-domain emails that are agents or services (comma-separated): their reports go to the test route. */
  readonly CONNECTIVITY_ALERT_EXCLUDED_EMAILS?: string
  /** Connectivity reports per user per minute. */
  readonly INCIDENT_LIMIT?: RateLimit
  // Test only (ENVIRONMENT=test).
  /** JSON {userId: {email, verified}} (primary project), {"<projectId>:<userId>": ...} for the others. */
  readonly STACK_TEST_EMAILS?: string
  readonly STACK_TEST_JWKS?: string
  /** JSON {userId: [teamId]} for primary-project users, {"<projectId>:<userId>": [teamId]} for the others; replaces Stack membership calls. */
  readonly STACK_TEST_TEAMS?: string
  /** JSON {dev, prod}: each deployed environment's APNS_TOPICS from wrangler.jsonc (vitest.config.ts). */
  readonly TEST_DEPLOYED_APNS_TOPICS?: string
}
