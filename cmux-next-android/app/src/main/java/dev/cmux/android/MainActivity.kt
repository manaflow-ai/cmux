package dev.cmux.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Design tokens, mirroring CmuxMobileDesign on iPhone: true-black dark, cmux accent. */
object Cmux {
    val bg = Color(0xFF000000)
    val surface = Color(0xFF121214)
    val surface2 = Color(0xFF1C1C1F)
    val text = Color(0xFFF2F2F2)
    val muted = Color(0xFF8E8E93)
    val accent = Color(0xFF7C6CFF)
    val green = Color(0xFF34C759)
    val orange = Color(0xFFFF9F0A)
}

/** Mock model, mirroring CmuxMobileModel (Team, Mac, Workspace, FeedEvent). */
data class Workspace(val name: String, val mac: String, val branch: String, val tabs: Int, val agent: String?, val busy: Boolean)
data class FeedEvent(val agent: String, val workspace: String, val title: String, val body: String, val ask: Boolean, val ago: String)

val mockWorkspaces = listOf(
    Workspace("cmux", "Lawrence's MacBook Pro", "feat-cmux-next", 6, "Claude Code", true),
    Workspace("cmux-platform", "Lawrence's MacBook Pro", "main", 3, "Codex", false),
    Workspace("ghostty", "mini-cmuxs-mac-mini-2", "main", 2, null, false),
    Workspace("cmux-next-android", "Lawrence's MacBook Pro", "feat-android", 4, "Claude Code", true),
)
val mockFeed = listOf(
    FeedEvent("Claude Code", "cmux", "Needs your answer", "Run the iOS kit tests on the fleet Mac before pushing?", true, "2m"),
    FeedEvent("Codex", "cmux-platform", "Finished", "Migrated device registry to Hyperdrive. 14 files changed, tests green.", false, "11m"),
    FeedEvent("Claude Code", "cmux-next-android", "Artifact", "Emulator screenshot of the Workspaces tab.", false, "18m"),
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val start = intent.getStringExtra("screen")
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(background = Cmux.bg, surface = Cmux.bg, primary = Cmux.accent)) {
                var signedIn by remember { mutableStateOf(start != null && start != "onboarding") }
                if (!signedIn) Onboarding { signedIn = true } else Shell(start)
            }
        }
    }
}

@Composable
fun Onboarding(onSignIn: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(Cmux.bg).systemBarsPadding().padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(88.dp).clip(RoundedCornerShape(22.dp)).background(Cmux.accent), contentAlignment = Alignment.Center) {
            Text(">_", color = Color.White, fontSize = 34.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(24.dp))
        Text("cmux", color = Cmux.text, fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Your Macs, terminals and agents,\nin your pocket.", color = Cmux.muted, fontSize = 17.sp, lineHeight = 22.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Spacer(Modifier.weight(1f))
        SignInButton("Continue with Google", Color.White, Color.Black, onSignIn)
        SignInButton("Continue with GitHub", Cmux.surface2, Cmux.text, onSignIn)
        SignInButton("Continue with email", Cmux.surface2, Cmux.text, onSignIn)
        Spacer(Modifier.height(12.dp))
        Text("Pair with the cmux app on your Mac after you sign in.", color = Cmux.muted, fontSize = 13.sp)
    }
}

@Composable
fun SignInButton(label: String, bg: Color, fg: Color, onClick: () -> Unit) {
    Button(onClick, Modifier.fillMaxWidth().padding(vertical = 5.dp).height(52.dp), shape = RoundedCornerShape(26.dp),
        colors = ButtonDefaults.buttonColors(containerColor = bg, contentColor = fg)) {
        Text(label, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

enum class Tab(val label: String, val icon: ImageVector) {
    Home("Home", Icons.Filled.ChatBubble), Workspaces("Workspaces", Icons.Filled.ViewAgenda),
    Feed("Feed", Icons.Filled.Notifications), Settings("Settings", Icons.Filled.Settings)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Shell(start: String?) {
    var tab by remember { mutableStateOf(Tab.entries.firstOrNull { it.name.equals(start, true) } ?: Tab.Home) }
    Scaffold(
        containerColor = Cmux.bg,
        topBar = {
            TopAppBar(
                title = { Text(tab.label, fontWeight = FontWeight.Bold, fontSize = 28.sp) },
                navigationIcon = { TeamBadge() },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Cmux.bg, titleContentColor = Cmux.text),
            )
        },
        bottomBar = {
            NavigationBar(containerColor = Cmux.surface) {
                Tab.entries.forEach { t ->
                    NavigationBarItem(selected = t == tab, onClick = { tab = t }, icon = {
                        if (t == Tab.Feed) BadgedBox({ Badge { Text("1") } }) { Icon(t.icon, null) } else Icon(t.icon, null)
                    }, label = { Text(t.label) },
                        colors = NavigationBarItemDefaults.colors(selectedIconColor = Cmux.accent, selectedTextColor = Cmux.accent,
                            indicatorColor = Cmux.surface2, unselectedIconColor = Cmux.muted, unselectedTextColor = Cmux.muted))
                }
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (tab) {
                Tab.Home -> HomeScreen(); Tab.Workspaces -> WorkspacesScreen()
                Tab.Feed -> FeedScreen(); Tab.Settings -> SettingsScreen()
            }
        }
    }
}

@Composable
fun TeamBadge() {
    Box(Modifier.padding(start = 12.dp, end = 8.dp).size(34.dp).clip(RoundedCornerShape(9.dp)).background(Cmux.orange),
        contentAlignment = Alignment.Center) { Text("M", color = Color.Black, fontWeight = FontWeight.Bold) }
}

@Composable
fun HomeScreen() {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { Bubble("What's running on my Macs right now?", mine = true) }
            item { Bubble("Two agents are working: Claude Code in cmux (feat-cmux-next) is waiting on your answer about the iOS kit tests, and Claude Code in cmux-next-android is building the emulator APK. Codex in cmux-platform finished 11 minutes ago.", mine = false) }
        }
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Cmux.surface2).padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("Ask Chief…", color = Cmux.muted, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ArrowUpward, null, tint = Color.Black, modifier = Modifier.size(28.dp).clip(CircleShape).background(Cmux.text).padding(4.dp))
        }
    }
}

@Composable
fun Bubble(text: String, mine: Boolean) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Text(text, color = Cmux.text, fontSize = 16.sp, lineHeight = 22.sp,
            modifier = if (mine) Modifier.widthIn(max = 280.dp).clip(RoundedCornerShape(20.dp)).background(Cmux.surface2).padding(12.dp) else Modifier)
    }
}

@Composable
fun WorkspacesScreen() {
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        items(mockWorkspaces) { w ->
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Cmux.surface).clickable {}.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Terminal, null, tint = Cmux.accent)
                    Spacer(Modifier.width(10.dp))
                    Text(w.name, color = Cmux.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Text("${w.tabs} tabs", color = Cmux.muted, fontSize = 13.sp)
                }
                Spacer(Modifier.height(6.dp))
                Text("${w.branch} · ${w.mac}", color = Cmux.muted, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                w.agent?.let {
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(8.dp).clip(CircleShape).background(if (w.busy) Cmux.green else Cmux.muted))
                        Spacer(Modifier.width(6.dp))
                        Text(if (w.busy) "$it working" else "$it idle", color = Cmux.text, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

@Composable
fun FeedScreen() {
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        items(mockFeed) { e ->
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Cmux.surface).padding(16.dp)) {
                Row {
                    Text("${e.agent} · ${e.workspace}", color = Cmux.muted, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    Text(e.ago, color = Cmux.muted, fontSize = 13.sp)
                }
                Spacer(Modifier.height(4.dp))
                Text(e.title, color = if (e.ask) Cmux.orange else Cmux.text, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                Spacer(Modifier.height(4.dp))
                Text(e.body, color = Cmux.text, fontSize = 15.sp, lineHeight = 20.sp)
                if (e.ask) {
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button({}, colors = ButtonDefaults.buttonColors(containerColor = Cmux.accent)) { Text("Yes") }
                        OutlinedButton({}) { Text("No", color = Cmux.text) }
                    }
                }
            }
        }
    }
}

@Composable
fun SettingsScreen() {
    val rows = listOf("Account" to "lawrence@manaflow.ai", "Team" to "Manaflow", "Paired Macs" to "2",
        "Transport" to "WebRTC, WireGuard fallback", "Require biometrics" to "On", "Version" to "0.1.0 (mock data)")
    Column(Modifier.fillMaxSize().padding(16.dp).clip(RoundedCornerShape(16.dp)).background(Cmux.surface)) {
        rows.forEachIndexed { i, (k, v) ->
            Row(Modifier.fillMaxWidth().padding(16.dp)) {
                Text(k, color = Cmux.text, modifier = Modifier.weight(1f)); Text(v, color = Cmux.muted)
            }
            if (i < rows.lastIndex) HorizontalDivider(color = Cmux.surface2)
        }
    }
}
