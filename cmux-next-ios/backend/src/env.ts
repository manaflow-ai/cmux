import type { LinkRelay } from "./link-relay.ts"
import type { HubRelay } from "./hub-relay.ts"
import type { TeamHub } from "./team-hub.ts"
import type { ChunkCache } from "./chunk-cache.ts"

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
  /** The link's WebSocket relay (src/link-relay.ts): one object per link session. */
  readonly LINK_RELAY: DurableObjectNamespace<LinkRelay>
  /** Per-pair sealed chunk cache (PROTOCOL.md "Sealed chunk cache"). */
  readonly CHUNK_CACHE: DurableObjectNamespace<ChunkCache>
  /** `off` refuses every relay join with 503 `relay_off` (the kill switch; PROTOCOL.md "WebSocket relay"). */
  readonly LINK_RELAY_MODE?: string
  /** `off` keeps no tail and replays nothing on a rejoin (RFD 0142 R3, src/link-relay.ts `RELAY_TAIL_MS`). */
  readonly LINK_RELAY_TAIL?: string
  /** What one user may relay per minute across all sessions, MiB (default 480: src/relay-access.ts). */
  readonly LINK_RELAY_USER_MIB_PER_MIN?: string
  /** Test only (ENVIRONMENT=test): `1` makes the hub's relay budget call throw (an overloaded hub). */
  readonly LINK_RELAY_TEST_BUDGET_ERROR?: string
  /**
   * `on` turns on the relay-held send queue (RFD 0142 R8, src/relay-hold.ts): a sealed send to a peer that is not
   * joined is acked in one relay RTT and held until it joins. Absent or anything else: off (the default).
   */
  readonly LINK_RELAY_HOLD?: string
  /**
   * `on` turns on the relay's sealed snapshot cache and delta catch-up (RFD 0142 R2 and R9, src/relay-cache.ts,
   * `/v1/relay-cache/...`). Absent or anything else: off (the default); every cache route answers 503
   * `relay_cache_off` and a client keeps today's path (the live link).
   */
  readonly LINK_RELAY_CACHE?: string
  /**
   * `on` turns on the hub's central relay region pick (RFD 0142 O2, src/region-pick.ts): each user's TeamHub learns
   * the relayed link's round trip per network pair and region from the phone's `link_stat` and places the next
   * relay where it ran fastest. Absent or anything else: off (the default); relays are placed by
   * `relayPlacement` alone, as before.
   */
  readonly LINK_RELAY_CENTRAL_PICK?: string
  /** The three-way hub (RFD 0142 R6): "off" refuses every hub join with 503 hub_off; clients keep their per-source path. */
  readonly HUB_RELAY: DurableObjectNamespace<HubRelay>
  readonly HUB_RELAY_MODE?: string
  /** Absent in tests: the memory store is used instead. */
  /** PlanetScale MySQL cmux-next-vitess (readwriter) through Hyperdrive; absent in tests (memory store). */
  readonly PS_MYSQL?: Hyperdrive
  /** Optional: the primary project's server key. Membership and invites then use the Stack server API for that project's users. */
  readonly STACK_SECRET_SERVER_KEY?: string
  readonly TURN_KEY_ID?: string
  readonly TURN_KEY_API_TOKEN?: string
  /** Our own TURN relay (deploy/turn): comma list of turn:/turns: URLs and its shared secret. When both are set, Cloudflare TURN is not used. */
  readonly TURN_SELF_URLS?: string
  readonly TURN_SELF_SECRET?: string
  readonly ICE_TTL_SECONDS?: string
  /** APNs (src/push.ts): all three or none. */
  readonly APNS_KEY_P8?: string
  readonly APNS_KEY_ID?: string
  readonly APNS_TEAM_ID?: string
  /** A second key of the same team for sandbox sends only (push.ts `signingConfig`): both or neither. */
  readonly APNS_SANDBOX_KEY_P8?: string
  readonly APNS_SANDBOX_KEY_ID?: string
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
  /** A fake MySQL connection: the store is the MySQL store on it instead of the memory store (test/schema-probe.test.ts). */
  readonly TEST_MYSQL_CONN?: import("./store-mysql.ts").MysqlConn
  /** JSON {dev, prod}: each deployed environment's APNS_TOPICS from wrangler.jsonc (vitest.config.ts). */
  readonly TEST_DEPLOYED_APNS_TOPICS?: string
}
