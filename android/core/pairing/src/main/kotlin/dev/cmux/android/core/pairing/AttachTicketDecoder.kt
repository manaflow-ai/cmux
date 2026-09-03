package dev.cmux.android.core.pairing

import java.net.URI
import java.net.URLDecoder

/**
 * Decodes a scanned cmux pairing QR URL into an [AttachTicket].
 *
 * Supported grammars:
 *  - v2 (Tailscale): `cmux-ios://attach?v=2&ub=<uid>&pc=<compat>&r=<host>:<port>[&r=...]`
 *  - v3 (Iroh): `cmux-ios://attach?v=3&i=<endpoint-id>[&d=<device-id>]`
 *
 * Scheme variants accepted: `cmux-ios`, `cmux-ios-dev` (dev builds).
 * Loopback hosts (127.0.0.1, localhost, ::1) are rejected to prevent the phone
 * from dialling itself.
 *
 * Uses java.net.URI for parsing (JVM-compatible, no Android dependency) so this
 * class is fully testable in JVM unit tests without Robolectric.
 */
object AttachTicketDecoder {

    private val ACCEPTED_SCHEMES = setOf("cmux-ios", "cmux-ios-dev")
    private val LOOPBACK_HOSTS = setOf("127.0.0.1", "localhost", "::1", "[::1]")
    private const val MAX_ROUTES = 8

    sealed class Result {
        data class Success(val ticket: AttachTicket) : Result()
        data class Error(val reason: DecodeError) : Result()
    }

    enum class DecodeError {
        INVALID_URL,
        UNSUPPORTED_VERSION,
        LOOPBACK_ROUTE_REJECTED,
        EMPTY_ROUTES,
        INVALID_PORT,
    }

    fun decode(rawUrl: String): Result {
        val uri = try {
            URI(rawUrl)
        } catch (e: Exception) {
            return Result.Error(DecodeError.INVALID_URL)
        }

        val scheme = uri.scheme?.lowercase() ?: return Result.Error(DecodeError.INVALID_URL)
        if (scheme !in ACCEPTED_SCHEMES) return Result.Error(DecodeError.INVALID_URL)
        if (uri.host != "attach") return Result.Error(DecodeError.INVALID_URL)

        val params = parseQueryParams(uri.rawQuery ?: "")
        val version = params["v"]?.firstOrNull()?.toIntOrNull()
            ?: return Result.Error(DecodeError.INVALID_URL)

        return when (version) {
            2 -> decodeV2(params)
            3 -> decodeV3(params)
            else -> Result.Error(DecodeError.UNSUPPORTED_VERSION)
        }
    }

    private fun decodeV2(params: Map<String, List<String>>): Result {
        val rawRoutes = params["r"] ?: emptyList()
        if (rawRoutes.isEmpty() || rawRoutes.size > MAX_ROUTES) {
            return Result.Error(DecodeError.EMPTY_ROUTES)
        }

        val routes = mutableListOf<AttachRoute>()
        for (rawRoute in rawRoutes) {
            val decoded = URLDecoder.decode(rawRoute, "UTF-8")
            val (host, port) = parseHostPort(decoded)
                ?: return Result.Error(DecodeError.INVALID_URL)
            if (port !in 1..65535) return Result.Error(DecodeError.INVALID_PORT)
            if (isLoopback(host)) return Result.Error(DecodeError.LOOPBACK_ROUTE_REJECTED)
            routes.add(AttachRoute(kind = AttachRoute.RouteKind.TAILSCALE, host = host, port = port))
        }

        val userId = params["ub"]?.firstOrNull()?.takeIf { it.isNotBlank() }
        val compat = params["pc"]?.firstOrNull()?.toIntOrNull() ?: 0

        return Result.Success(
            AttachTicket(routes = routes, macUserId = userId, compatibilityVersion = compat)
        )
    }

    private fun decodeV3(params: Map<String, List<String>>): Result {
        val endpointId = params["i"]?.firstOrNull()?.takeIf { it.isNotBlank() }
            ?: return Result.Error(DecodeError.INVALID_URL)
        val deviceId = params["d"]?.firstOrNull()?.takeIf { it.isNotBlank() } ?: ""

        val route = AttachRoute(
            kind = AttachRoute.RouteKind.IROH_ENDPOINT,
            host = endpointId,
            port = 0,
        )
        return Result.Success(
            AttachTicket(routes = listOf(route), macUserId = null, macDeviceId = deviceId)
        )
    }

    /**
     * Parse query string into a multi-value map.
     * Handles repeated keys (e.g., `r=host1&r=host2`).
     */
    private fun parseQueryParams(query: String): Map<String, List<String>> {
        if (query.isBlank()) return emptyMap()
        val result = mutableMapOf<String, MutableList<String>>()
        query.split("&").forEach { pair ->
            val idx = pair.indexOf('=')
            if (idx < 0) return@forEach
            val key = URLDecoder.decode(pair.substring(0, idx), "UTF-8")
            val value = URLDecoder.decode(pair.substring(idx + 1), "UTF-8")
            result.getOrPut(key) { mutableListOf() }.add(value)
        }
        return result
    }

    /** Parse `host:port` or `[ipv6]:port`. Returns null on malformed input. */
    private fun parseHostPort(raw: String): Pair<String, Int>? {
        val trimmed = raw.trim()
        return if (trimmed.startsWith("[")) {
            // IPv6: [addr]:port
            val closing = trimmed.indexOf(']')
            if (closing < 0) return null
            val host = trimmed.substring(1, closing)
            val rest = trimmed.substring(closing + 1)
            if (!rest.startsWith(":")) return null
            val port = rest.substring(1).toIntOrNull() ?: return null
            host to port
        } else {
            val idx = trimmed.lastIndexOf(':')
            if (idx < 0) return null
            val host = trimmed.substring(0, idx)
            val port = trimmed.substring(idx + 1).toIntOrNull() ?: return null
            host to port
        }
    }

    private fun isLoopback(host: String): Boolean = host.lowercase() in LOOPBACK_HOSTS
}
