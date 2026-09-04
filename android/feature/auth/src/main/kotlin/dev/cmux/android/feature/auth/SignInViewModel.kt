package dev.cmux.android.feature.auth

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import javax.inject.Inject
import javax.net.ssl.HttpsURLConnection

sealed interface SignInState {
    data object Loading : SignInState
    data object SignedIn : SignInState
    data object SignedOut : SignInState
    data class Error(val message: String) : SignInState
}

@HiltViewModel
class SignInViewModel @Inject constructor(
    private val tokenStore: StackAuthTokenStore,
) : ViewModel() {

    private val _state = MutableStateFlow<SignInState>(SignInState.Loading)
    val state: StateFlow<SignInState> = _state.asStateFlow()

    private val stackBaseUrl = "https://api.stack-auth.com"
    // Development project credentials (from AuthEnvironment.swift)
    private val stackProjectId = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    private val stackPublishableKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    // Same scheme Stack Auth whitelists for mobile OAuth (matches iOS SDK)
    private val redirectUri = "stack-auth-mobile-oauth-url://success"

    private var pendingCodeVerifier: String? = null
    private var pendingState: String? = null

    init {
        checkExistingSession()
        // Receive auth codes delivered by MainActivity via the shared channel
        viewModelScope.launch {
            authCallbackChannel.collect { code -> handleAuthCallback(code) }
        }
    }

    companion object {
        /** MainActivity emits auth codes here; the active ViewModel consumes them. */
        val authCallbackChannel = MutableSharedFlow<String>(extraBufferCapacity = 1)
    }

    private fun checkExistingSession() {
        viewModelScope.launch {
            _state.value = if (tokenStore.isSignedIn) SignInState.SignedIn else SignInState.SignedOut
        }
    }

    /** Build the Stack Auth OAuth URL for Google sign-in with PKCE. */
    fun buildAuthUrl(): String {
        val state = generateRandomBase64Url(32)
        val codeVerifier = generateRandomBase64Url(64)
        val codeChallenge = sha256Base64Url(codeVerifier)
        pendingState = state
        pendingCodeVerifier = codeVerifier

        return Uri.parse("$stackBaseUrl/api/v1/auth/oauth/authorize/google")
            .buildUpon()
            .appendQueryParameter("client_id", stackProjectId)
            .appendQueryParameter("client_secret", stackPublishableKey)
            .appendQueryParameter("redirect_uri", redirectUri)
            .appendQueryParameter("scope", "legacy")
            .appendQueryParameter("state", state)
            .appendQueryParameter("grant_type", "authorization_code")
            .appendQueryParameter("code_challenge", codeChallenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("type", "authenticate")
            .appendQueryParameter("error_redirect_uri", redirectUri)
            .build()
            .toString()
    }

    /**
     * Handle the OAuth callback deep link `dev.cmux.android://auth-callback?code=...`.
     * Exchanges the authorization code for access + refresh tokens.
     */
    fun handleAuthCallback(code: String) {
        val verifier = pendingCodeVerifier ?: run {
            _state.value = SignInState.Error("Missing PKCE verifier")
            return
        }
        viewModelScope.launch {
            _state.value = SignInState.Loading
            try {
                val tokens = exchangeCodeForTokens(code, verifier)
                tokenStore.storeTokens(
                    accessToken = tokens.first,
                    refreshToken = tokens.second,
                    userId = null,
                )
                pendingCodeVerifier = null
                pendingState = null
                _state.value = SignInState.SignedIn
            } catch (e: Exception) {
                _state.value = SignInState.Error(e.message ?: "Token exchange failed")
            }
        }
    }

    private suspend fun exchangeCodeForTokens(code: String, codeVerifier: String): Pair<String, String> =
        withContext(Dispatchers.IO) {
            val tokenUrl = URL("$stackBaseUrl/api/v1/auth/oauth/token")
            val body = "grant_type=authorization_code" +
                "&client_id=${Uri.encode(stackProjectId)}" +
                "&client_secret=${Uri.encode(stackPublishableKey)}" +
                "&code=${Uri.encode(code)}" +
                "&redirect_uri=${Uri.encode(redirectUri)}" +
                "&code_verifier=${Uri.encode(codeVerifier)}"

            val connection = tokenUrl.openConnection() as HttpsURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            connection.setRequestProperty("X-Stack-Project-Id", stackProjectId)
            connection.setRequestProperty("X-Stack-Publishable-Client-Key", stackPublishableKey)
            connection.setRequestProperty("X-Stack-Access-Type", "client")
            connection.doOutput = true
            connection.outputStream.use { it.write(body.toByteArray()) }

            val responseCode = connection.responseCode
            val responseBody = (if (responseCode in 200..299) connection.inputStream
            else connection.errorStream)
                .bufferedReader()
                .readText()
            connection.disconnect()

            if (responseCode !in 200..299) {
                throw Exception("Token exchange failed ($responseCode): $responseBody")
            }

            val json = JSONObject(responseBody)
            val accessToken = json.getString("access_token")
            val refreshToken = json.optString("refresh_token", "")
            accessToken to refreshToken
        }

    fun retry() {
        _state.value = SignInState.SignedOut
    }

    private fun generateRandomBase64Url(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        SecureRandom().nextBytes(bytes)
        return android.util.Base64.encodeToString(bytes, android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP)
    }

    private fun sha256Base64Url(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.US_ASCII))
        return android.util.Base64.encodeToString(digest, android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP)
    }
}
