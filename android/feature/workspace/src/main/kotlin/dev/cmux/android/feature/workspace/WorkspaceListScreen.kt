package dev.cmux.android.feature.workspace

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.cmux.android.core.rpc.WorkspaceDto

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkspaceListScreen(
    onOpenTerminal: (workspaceId: String, surfaceId: String) -> Unit,
    onOpenBrowser: (workspaceId: String, panelId: String) -> Unit,
    viewModel: WorkspaceViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Workspaces") },
                actions = {
                    IconButton(onClick = { viewModel.refresh() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh")
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when (val s = state) {
                is WorkspaceUiState.Loading -> {
                    CircularProgressIndicator(modifier = Modifier.align(Alignment.Center))
                }
                is WorkspaceUiState.Error -> {
                    Column(
                        modifier = Modifier.align(Alignment.Center),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Error: ${s.message}")
                        Button(onClick = { viewModel.refresh() }) { Text("Retry") }
                    }
                }
                is WorkspaceUiState.Loaded -> {
                    if (s.workspaces.isEmpty()) {
                        Text(
                            "No workspaces found",
                            modifier = Modifier.align(Alignment.Center),
                        )
                    } else {
                        LazyColumn(modifier = Modifier.fillMaxSize()) {
                            items(s.workspaces) { ws ->
                                WorkspaceRow(
                                    workspace = ws,
                                    onOpenTerminal = { surfaceId ->
                                        onOpenTerminal(ws.workspace_id, surfaceId)
                                    },
                                    onOpenBrowser = { panelId ->
                                        onOpenBrowser(ws.workspace_id, panelId)
                                    },
                                )
                                HorizontalDivider()
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun WorkspaceRow(
    workspace: WorkspaceDto,
    onOpenTerminal: (surfaceId: String) -> Unit,
    onOpenBrowser: (panelId: String) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                workspace.title,
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (workspace.unread_count > 0) {
                Badge { Text("${workspace.unread_count}") }
            }
        }
        workspace.directory?.let { dir ->
            Text(
                dir,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.height(8.dp))
        if (workspace.terminals.isNotEmpty()) {
            Text(
                "${workspace.terminals.size} terminal(s)",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.clickable {
                    onOpenTerminal(workspace.terminals.first().surface_id)
                },
            )
        }
    }
}
