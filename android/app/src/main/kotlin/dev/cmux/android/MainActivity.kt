package dev.cmux.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import dagger.hilt.android.AndroidEntryPoint
import dev.cmux.android.feature.auth.SignInViewModel
import dev.cmux.android.ui.navigation.CmuxNavGraph
import dev.cmux.android.ui.theme.CmuxTheme
import kotlinx.coroutines.launch

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Handle callback delivered via the launch intent (cold start)
        handleAuthIntent(intent)
        setContent {
            CmuxTheme {
                CmuxNavGraph()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleAuthIntent(intent)
    }

    private fun handleAuthIntent(intent: Intent) {
        val uri = intent.data ?: return
        if (uri.scheme == "stack-auth-mobile-oauth-url") {
            val code = uri.getQueryParameter("code") ?: return
            lifecycleScope.launch {
                SignInViewModel.authCallbackChannel.emit(code)
            }
        }
    }
}
