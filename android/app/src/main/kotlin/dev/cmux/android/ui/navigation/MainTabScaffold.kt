package dev.cmux.android.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import dev.cmux.android.feature.workspace.NotificationsScreen
import dev.cmux.android.feature.workspace.WorkspaceListScreen

object TabRoutes {
    const val WORKSPACES = "tab_workspaces"
    const val NOTIFICATIONS = "tab_notifications"
}

/**
 * Wraps only the two top-level tab destinations (Workspaces, Notifications) —
 * drill-in screens like the terminal or browser stream stay outside this
 * scaffold's nav graph, matching iOS's MobilePrimaryTabScaffold scope.
 */
@Composable
fun MainTabScaffold(
    onOpenTerminal: (workspaceId: String, surfaceId: String) -> Unit,
    onOpenBrowser: (workspaceId: String, panelId: String) -> Unit,
) {
    val tabNavController = rememberNavController()

    Scaffold(
        bottomBar = {
            val currentEntry by tabNavController.currentBackStackEntryAsState()
            val currentDestination = currentEntry?.destination

            NavigationBar {
                NavigationBarItem(
                    selected = currentDestination?.hierarchy?.any { it.route == TabRoutes.WORKSPACES } == true,
                    onClick = {
                        tabNavController.navigate(TabRoutes.WORKSPACES) {
                            popUpTo(tabNavController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(Icons.AutoMirrored.Filled.List, contentDescription = "Workspaces") },
                    label = { Text("Workspaces") },
                )
                NavigationBarItem(
                    selected = currentDestination?.hierarchy?.any { it.route == TabRoutes.NOTIFICATIONS } == true,
                    onClick = {
                        tabNavController.navigate(TabRoutes.NOTIFICATIONS) {
                            popUpTo(tabNavController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    icon = { Icon(Icons.Default.Notifications, contentDescription = "Notifications") },
                    label = { Text("Notifications") },
                )
            }
        },
    ) { padding ->
        NavHost(
            navController = tabNavController,
            startDestination = TabRoutes.WORKSPACES,
            modifier = Modifier.padding(padding),
        ) {
            composable(TabRoutes.WORKSPACES) {
                WorkspaceListScreen(
                    onOpenTerminal = onOpenTerminal,
                    onOpenBrowser = onOpenBrowser,
                )
            }
            composable(TabRoutes.NOTIFICATIONS) {
                NotificationsScreen(
                    onOpenWorkspace = { workspaceId, surfaceId ->
                        if (surfaceId != null) {
                            onOpenTerminal(workspaceId, surfaceId)
                        } else {
                            tabNavController.navigate(TabRoutes.WORKSPACES) {
                                launchSingleTop = true
                            }
                        }
                    },
                )
            }
        }
    }
}
