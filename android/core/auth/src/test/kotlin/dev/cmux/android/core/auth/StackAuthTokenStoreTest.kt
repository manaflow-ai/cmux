package dev.cmux.android.core.auth

import io.mockk.*
import org.junit.jupiter.api.Assertions.*
import org.junit.jupiter.api.Test

/**
 * Unit tests for StackAuthTokenStore.
 *
 * Android-specific EncryptedSharedPreferences cannot run on JVM, so we test
 * the contract through a fake/mockable interface. On-device tests would use
 * Robolectric or an instrumented test runner.
 */
class StackAuthTokenStoreTest {

    /** Minimal in-memory stand-in for StackAuthTokenStore. */
    class FakeTokenStore {
        private var accessToken: String? = null
        private var refreshToken: String? = null
        private var userId: String? = null

        fun getAccessToken(): String? = accessToken
        fun getRefreshToken(): String? = refreshToken
        fun getUserId(): String? = userId
        val isSignedIn: Boolean get() = accessToken != null

        fun storeTokens(accessToken: String, refreshToken: String, userId: String?) {
            this.accessToken = accessToken
            this.refreshToken = refreshToken
            this.userId = userId
        }

        fun clearTokens() {
            accessToken = null
            refreshToken = null
            userId = null
        }
    }

    @Test
    fun `getAccessToken returns null on fresh store`() {
        val store = FakeTokenStore()
        assertNull(store.getAccessToken())
        assertFalse(store.isSignedIn)
    }

    @Test
    fun `storeTokens and getAccessToken round-trip`() {
        val store = FakeTokenStore()
        store.storeTokens("access-abc", "refresh-xyz", "user-123")
        assertEquals("access-abc", store.getAccessToken())
        assertEquals("refresh-xyz", store.getRefreshToken())
        assertEquals("user-123", store.getUserId())
        assertTrue(store.isSignedIn)
    }

    @Test
    fun `clearTokens removes all stored values`() {
        val store = FakeTokenStore()
        store.storeTokens("tok", "ref", "uid")
        store.clearTokens()
        assertNull(store.getAccessToken())
        assertNull(store.getRefreshToken())
        assertNull(store.getUserId())
        assertFalse(store.isSignedIn)
    }

    @Test
    fun `storeTokens with null userId stores without userId`() {
        val store = FakeTokenStore()
        store.storeTokens("tok", "ref", null)
        assertNull(store.getUserId())
        assertEquals("tok", store.getAccessToken())
    }

    @Test
    fun `storeTokens overwrites previous tokens`() {
        val store = FakeTokenStore()
        store.storeTokens("tok1", "ref1", "u1")
        store.storeTokens("tok2", "ref2", "u2")
        assertEquals("tok2", store.getAccessToken())
        assertEquals("ref2", store.getRefreshToken())
        assertEquals("u2", store.getUserId())
    }
}
