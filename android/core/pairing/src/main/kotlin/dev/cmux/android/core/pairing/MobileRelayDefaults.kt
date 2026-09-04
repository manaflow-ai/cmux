package dev.cmux.android.core.pairing

/**
 * Resolves the base URL of the Cloudflare mobile pairing relay
 * (`workers/presence`'s MobilePairingRelay Durable Object — the same worker
 * already deployed at `presence.cmux.dev`, see workers/presence/README.md).
 *
 * Mirrors the Mac's `PresenceHeartbeatClient.resolvedServiceURL()`: an env
 * override wins (for local `wrangler dev`/per-developer instances), otherwise
 * DEBUG builds default to the dev/staging instance and release builds to
 * production.
 */
object MobileRelayDefaults {
    /** Env override, e.g. set via `adb shell setprop` or a debug build config
     * field when pointing at a per-developer `wrangler dev` instance. */
    const val BASE_URL_ENV_KEY = "CMUX_PRESENCE_BASE_URL"

    /** The dev/staging worker — same instance the Mac's Debug builds use. */
    const val DEBUG_DEFAULT_BASE_URL = "https://cmux-presence-dev.debussy.workers.dev"

    /** The production presence worker. */
    const val PRODUCTION_BASE_URL = "https://presence.cmux.dev"

    /**
     * The resolved base URL (no trailing slash), or the DEBUG/release default
     * when [envOverride] is blank.
     */
    fun resolvedBaseUrl(isDebug: Boolean, envOverride: String? = System.getenv(BASE_URL_ENV_KEY)): String {
        val trimmedOverride = envOverride?.trim()
        val base = if (!trimmedOverride.isNullOrEmpty()) {
            trimmedOverride
        } else if (isDebug) {
            DEBUG_DEFAULT_BASE_URL
        } else {
            PRODUCTION_BASE_URL
        }
        return base.removeSuffix("/")
    }

    /** The `/client` leg WebSocket URL a phone/Android app dials for `macDeviceId`. */
    fun clientRelayUrl(macDeviceId: String, isDebug: Boolean): String {
        val base = resolvedBaseUrl(isDebug).replaceFirst(Regex("^http"), "ws")
        return "$base/v1/mobile-relay/$macDeviceId/client"
    }
}
