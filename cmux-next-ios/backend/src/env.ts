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
  // Test only (ENVIRONMENT=test).
  readonly STACK_TEST_JWKS?: string
  /** JSON {userId: [teamId]} for primary-project users, {"<projectId>:<userId>": [teamId]} for the others; replaces Stack membership calls. */
  readonly STACK_TEST_TEAMS?: string
}
