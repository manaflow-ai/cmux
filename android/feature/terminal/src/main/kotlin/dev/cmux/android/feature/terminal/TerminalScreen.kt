package dev.cmux.android.feature.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    workspaceId: String,
    surfaceId: String,
    onBack: () -> Unit,
    viewModel: TerminalViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val activeSurfaceId by viewModel.activeSurfaceId.collectAsStateWithLifecycle()
    val siblingTerminals by viewModel.siblingTerminals.collectAsStateWithLifecycle()
    var inputText by remember { mutableStateOf("") }
    var pickerExpanded by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    val activeTitle = siblingTerminals.firstOrNull { it.id == activeSurfaceId }
                        ?.title?.takeIf { it.isNotBlank() } ?: "Terminal"
                    Box {
                        TextButton(onClick = { pickerExpanded = true }, enabled = siblingTerminals.size > 1) {
                            Text(activeTitle, fontFamily = FontFamily.Monospace, color = Color.White)
                            if (siblingTerminals.size > 1) {
                                Icon(Icons.Default.ArrowDropDown, contentDescription = "Switch terminal", tint = Color.White)
                            }
                        }
                        DropdownMenu(expanded = pickerExpanded, onDismissRequest = { pickerExpanded = false }) {
                            siblingTerminals.forEach { terminal ->
                                DropdownMenuItem(
                                    text = {
                                        Text(terminal.title?.takeIf { it.isNotBlank() } ?: terminal.id)
                                    },
                                    leadingIcon = if (terminal.id == activeSurfaceId) {
                                        { Icon(Icons.Default.Check, contentDescription = null) }
                                    } else null,
                                    onClick = {
                                        pickerExpanded = false
                                        viewModel.switchSurface(terminal.id)
                                    },
                                )
                            }
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(Color(0xFF0D0D0D)),
        ) {
            when (val s = state) {
                is TerminalUiState.Connecting -> {
                    Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
                is TerminalUiState.Error -> {
                    Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        Text("Error: ${s.message}", color = Color.Red)
                    }
                }
                is TerminalUiState.Connected -> {
                    TerminalCanvas(
                        snapshot = s.snapshot,
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .padding(8.dp),
                        onScroll = viewModel::scroll,
                    )
                }
            }

            // Input row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color(0xFF1E1E1E))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicTextField(
                    value = inputText,
                    onValueChange = { inputText = it },
                    textStyle = TextStyle(
                        color = Color.White,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 13.sp,
                    ),
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                Spacer(Modifier.width(8.dp))
                Button(
                    onClick = {
                        viewModel.sendInput(inputText + "\n")
                        inputText = ""
                    },
                ) {
                    Text("Send")
                }
            }
        }
    }
}
