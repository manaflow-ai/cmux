package dev.cmux.android.feature.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import dev.cmux.android.core.auth.StackAuthTokenStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

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

    // Stack Auth project details (populated from the Mac app's auth config).
    // In production, these come from a config file or BuildConfig.
    private val stackProjectId = "dev.cmux"
    private val stackPublishableKey = "pk_live_placeholder"
    private val redirectUri = "dev.cmux.android://auth-callback"

    init {
        checkExistingSession()
    }

    private fun checkExistingSession() {
        viewModelScope.launch {
            _state.value = if (tokenStore.isSignedIn) {
                SignInState.SignedIn
            } else {
                SignInState.SignedOut
            }
        }
    }

    /** Build the Stack Auth OAuth authorization URL. */
    fun buildAuthUrl(): String {
        return "https://app.stackauth.com/oauth2/authorize" +
            "?client_id=$stackPublishableKey" +
            "&redirect_uri=$redirectUri" +
            "&response_type=code" +
            "&scope=openid profile email offline_access"
    }

    /**
     * Handle the OAuth callback. Called from MainActivity when the deep link
     * `dev.cmux.android://auth-callback?code=...` arrives.
     */
    fun handleAuthCallback(code: String) {
        viewModelScope.launch {
            _state.value = SignInState.Loading
            try {
                // In production: exchange code for tokens via Stack Auth token endpoint.
                // For the demo, we store placeholder tokens to unblock the pairing flow.
                tokenStore.storeTokens(
                    accessToken = "demo-access-token-$code",
                    refreshToken = "demo-refresh-token",
                    userId = null,
                )
                _state.value = SignInState.SignedIn
            } catch (e: Exception) {
                _state.value = SignInState.Error(e.message ?: "Unknown error")
            }
        }
    }

    fun retry() {
        _state.value = SignInState.SignedOut
    }
}
