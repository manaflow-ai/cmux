package dev.cmux.android.core.pairing

import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

class MobileRelayDefaultsTest {

    @Test
    fun `debug build with no override resolves to the dev worker`() {
        assertEquals(
            MobileRelayDefaults.DEBUG_DEFAULT_BASE_URL,
            MobileRelayDefaults.resolvedBaseUrl(isDebug = true, envOverride = null),
        )
    }

    @Test
    fun `release build with no override resolves to production`() {
        assertEquals(
            MobileRelayDefaults.PRODUCTION_BASE_URL,
            MobileRelayDefaults.resolvedBaseUrl(isDebug = false, envOverride = null),
        )
    }

    @Test
    fun `env override wins over both debug and release defaults`() {
        val override = "https://cmux-presence-dev-alice.example.workers.dev"
        assertEquals(override, MobileRelayDefaults.resolvedBaseUrl(isDebug = true, envOverride = override))
        assertEquals(override, MobileRelayDefaults.resolvedBaseUrl(isDebug = false, envOverride = override))
    }

    @Test
    fun `blank env override is ignored`() {
        assertEquals(
            MobileRelayDefaults.PRODUCTION_BASE_URL,
            MobileRelayDefaults.resolvedBaseUrl(isDebug = false, envOverride = "   "),
        )
    }

    @Test
    fun `client relay url swaps scheme to ws and appends the device path`() {
        val url = MobileRelayDefaults.clientRelayUrl("mac-device-abc", isDebug = false)
        assertEquals("wss://presence.cmux.dev/v1/mobile-relay/mac-device-abc/client", url)
    }

    @Test
    fun `client relay url strips a trailing slash from the base`() {
        val url = MobileRelayDefaults.clientRelayUrl(
            "mac-device-abc",
            isDebug = false,
        )
        assertFalse(url.contains("//v1"), "should not double up slashes: $url")
    }
}
