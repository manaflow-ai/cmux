package dev.cmux.android.core.pairing

/**
 * A decoded pairing ticket containing one or more routes to a paired Mac.
 */
data class AttachTicket(
    /** Mac's tailscale/TCP routes in priority order. */
    val routes: List<AttachRoute>,
    /** Stack user ID from the QR code (used for account preflight). */
    val macUserId: String?,
    /** Pairing compatibility version. */
    val compatibilityVersion: Int = 0,
    /** Mac device ID (may be empty for v2 QR codes; populated post-handshake). */
    val macDeviceId: String = "",
    /** Display name (populated post-handshake from mobile.host.status). */
    val macDisplayName: String? = null,
)

data class AttachRoute(
    val kind: RouteKind,
    val host: String,
    val port: Int,
) {
    enum class RouteKind { TAILSCALE, IROH_ENDPOINT, LOOPBACK }
}

/** Default port used when none is specified in a pairing code. */
const val DEFAULT_PORT = 58465
