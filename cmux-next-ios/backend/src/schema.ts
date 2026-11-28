import { boolean, index, pgTable, primaryKey, text, timestamp, uuid } from "drizzle-orm/pg-core"

/** A phone or Mac registered by its owner (PROTOCOL.md "Devices"). The deviceId is client generated. */
export const devices = pgTable(
  "devices",
  {
    deviceId: uuid("device_id").primaryKey(),
    /**
     * Build space (PROTOCOL.md "Build spaces"): "" for stable and nightly, `dev:<slug>` for a dev build. Every
     * read filters on it. Device ids stay the key: each build has its own id, and an id held by another space
     * is refused, never moved.
     */
    space: text("space").notNull().default(""),
    /** Owner key: the Stack sub (primary project) or `<projectId>:<sub>` (other projects). */
    ownerUserId: text("owner_user_id").notNull(),
    teamId: text("team_id").notNull(),
    kind: text("kind", { enum: ["mac", "phone"] }).notNull(),
    name: text("name").notNull(),
    wgPublicKey: text("wg_public_key"),
    /**
     * A Mac's machine id (PROTOCOL.md "Devices"): the same for every cmux build on one computer and owner, a
     * keyed hash the Mac derives (never the raw hardware id). Null for phones and for Macs that never sent one.
     */
    machineId: text("machine_id"),
    modelKind: text("model_kind"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
    lastSeenAt: timestamp("last_seen_at", { withTimezone: true })
  },
  (t) => [index("devices_team_kind_idx").on(t.teamId, t.kind), index("devices_owner_idx").on(t.ownerUserId)]
)

/** Per user, per team appearance in the app's team sidebar. `user_id` is the owner key, as in devices. */
export const teamPrefs = pgTable(
  "team_prefs",
  {
    /** The owner key; a dev space's row has the space in front (store-types.ts prefsUserKey). */
    userId: text("user_id").notNull(),
    teamId: text("team_id").notNull(),
    /** Build space, as in devices. */
    space: text("space").notNull().default(""),
    color: text("color"),
    emoji: text("emoji"),
    /** No filled background behind the icon. Only with a one-grapheme `emoji`; `color` stays the fallback. */
    transparent: boolean("transparent").notNull().default(false),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow()
  },
  (t) => [primaryKey({ columns: [t.userId, t.teamId] })]
)

/**
 * The APNs token of a phone (PROTOCOL.md `PUT /v1/devices/:deviceId/push`). One per phone; deleted with the
 * device. `owner_user_id` is the device's owner key, so a notify reads the owner's targets in one query.
 */
export const pushTokens = pgTable(
  "push_tokens",
  {
    deviceId: uuid("device_id").primaryKey(),
    /** The phone's build space, as its device row. */
    space: text("space").notNull().default(""),
    ownerUserId: text("owner_user_id").notNull(),
    token: text("token").notNull(),
    environment: text("environment", { enum: ["sandbox", "production"] }).notNull(),
    topic: text("topic").notNull(),
    /** Comma-separated event kinds this phone wants (question, permission, completed, failed, chief). */
    kinds: text("kinds").notNull(),
    /** Comma-separated Mac device ids this phone wants no push from (0.13.0); null is none. */
    mutedMacs: text("muted_macs"),
    /** Show previews (0.13.0): false hides content in the banner; null (older rows) is true. */
    previews: boolean("previews"),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow()
  },
  (t) => [index("push_tokens_owner_idx").on(t.ownerUserId)]
)
