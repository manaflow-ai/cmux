package dev.cmux.android.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import dev.cmux.android.feature.auth.SignInScreen
import dev.cmux.android.feature.browser.BrowserStreamScreen
import dev.cmux.android.feature.pairing.PairingScannerScreen
import dev.cmux.android.feature.terminal.TerminalScreen
import dev.cmux.android.feature.workspace.WorkspaceListScreen

object Routes {
    const val STARTUP = "startup"
    const val SIGN_IN = "sign_in"
    const val PAIRING = "pairing"
    const val WORKSPACE_LIST = "workspace_list"
    const val TERMINAL = "terminal/{workspaceId}/{surfaceId}"
    const val BROWSER = "browser/{workspaceId}/{panelId}"

    fun terminal(workspaceId: String, surfaceId: String) = "terminal/$workspaceId/$surfaceId"
    fun browser(workspaceId: String, panelId: String) = "browser/$workspaceId/$panelId"
}

@Composable
fun CmuxNavGraph() {
    val navController = rememberNavController()
    val startupViewModel: StartupViewModel = hiltViewModel()

    NavHost(
        navController = navController,
        startDestination = Routes.STARTUP,
    ) {
        composable(Routes.STARTUP) {
            val destination by startupViewModel.destination.collectAsStateWithLifecycle()

            LaunchedEffect(destination) {
                when (destination) {
                    StartupViewModel.Destination.SignIn ->
                        navController.navigate(Routes.SIGN_IN) {
                            popUpTo(Routes.STARTUP) { inclusive = true }
                        }
                    StartupViewModel.Destination.Pairing ->
                        navController.navigate(Routes.PAIRING) {
                            popUpTo(Routes.STARTUP) { inclusive = true }
                        }
                    StartupViewModel.Destination.Workspaces ->
                        navController.navigate(Routes.WORKSPACE_LIST) {
                            popUpTo(Routes.STARTUP) { inclusive = true }
                        }
                    StartupViewModel.Destination.Loading -> Unit
                }
            }

            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }

        composable(Routes.SIGN_IN) {
            SignInScreen(
                onSignedIn = {
                    // Re-run startup logic (auto-connects in debug, navigates to workspaces)
                    navController.navigate(Routes.STARTUP) {
                        popUpTo(Routes.SIGN_IN) { inclusive = true }
                    }
                }
            )
        }

        composable(Routes.PAIRING) {
            PairingScannerScreen(
                onPaired = {
                    navController.navigate(Routes.WORKSPACE_LIST) {
                        popUpTo(Routes.PAIRING) { inclusive = true }
                    }
                }
            )
        }

        composable(Routes.WORKSPACE_LIST) {
            WorkspaceListScreen(
                onOpenTerminal = { wsId, surfaceId ->
                    navController.navigate(Routes.terminal(wsId, surfaceId))
                },
                onOpenBrowser = { wsId, panelId ->
                    navController.navigate(Routes.browser(wsId, panelId))
                },
            )
        }

        composable(
            Routes.TERMINAL,
            arguments = listOf(
                navArgument("workspaceId") { type = NavType.StringType },
                navArgument("surfaceId") { type = NavType.StringType },
            ),
        ) { backStack ->
            TerminalScreen(
                workspaceId = backStack.arguments?.getString("workspaceId") ?: "",
                surfaceId = backStack.arguments?.getString("surfaceId") ?: "",
                onBack = { navController.popBackStack() },
            )
        }

        composable(
            Routes.BROWSER,
            arguments = listOf(
                navArgument("workspaceId") { type = NavType.StringType },
                navArgument("panelId") { type = NavType.StringType },
            ),
        ) { backStack ->
            BrowserStreamScreen(
                workspaceId = backStack.arguments?.getString("workspaceId") ?: "",
                panelId = backStack.arguments?.getString("panelId") ?: "",
                onBack = { navController.popBackStack() },
            )
        }
    }
}
