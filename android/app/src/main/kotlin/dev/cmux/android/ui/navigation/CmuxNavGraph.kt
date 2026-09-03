package dev.cmux.android.ui.navigation

import androidx.compose.runtime.Composable
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

    NavHost(
        navController = navController,
        startDestination = Routes.SIGN_IN,
    ) {
        composable(Routes.SIGN_IN) {
            SignInScreen(
                onSignedIn = { navController.navigate(Routes.PAIRING) }
            )
        }
        composable(Routes.PAIRING) {
            PairingScannerScreen(
                onPaired = { navController.navigate(Routes.WORKSPACE_LIST) }
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
