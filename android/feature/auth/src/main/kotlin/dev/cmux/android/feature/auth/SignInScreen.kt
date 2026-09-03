package dev.cmux.android.feature.auth

import androidx.activity.compose.LocalActivity
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.cmux.android.core.auth.StackAuthTokenStore
import javax.inject.Inject

@Composable
fun SignInScreen(
    onSignedIn: () -> Unit,
    viewModel: SignInViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val activity = LocalActivity.current

    LaunchedEffect(state) {
        if (state is SignInState.SignedIn) onSignedIn()
    }

    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        when (val s = state) {
            is SignInState.Loading -> CircularProgressIndicator()
            is SignInState.SignedIn -> CircularProgressIndicator()
            is SignInState.SignedOut -> {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("cmux", style = MaterialTheme.typography.headlineLarge)
                    Text("Sign in to connect to your Mac")
                    Button(onClick = {
                        // Open Stack Auth OAuth flow in Chrome Custom Tab
                        val authUrl = viewModel.buildAuthUrl()
                        val intent = CustomTabsIntent.Builder().build()
                        activity?.let { intent.launchUrl(it, authUrl.toUri()) }
                    }) {
                        Text("Sign In")
                    }
                }
            }
            is SignInState.Error -> {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("Sign in failed: ${s.message}")
                    Button(onClick = { viewModel.retry() }) { Text("Retry") }
                }
            }
        }
    }
}
