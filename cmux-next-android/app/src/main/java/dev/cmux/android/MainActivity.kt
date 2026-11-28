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
    Home("Home", Icons.Filled.Home), DMs("DMs", Icons.Filled.Forum), Feed("Feed", Icons.Filled.Notifications),
    Search("Search", Icons.Filled.Search), More("More", Icons.Filled.MoreHoriz)
}

data class Dm(val name: String, val last: String, val ago: String, val unread: Int, val agent: Boolean, val online: Boolean)
val mockDms = listOf(
    Dm("Chief", "Two agents are working; one is waiting on you.", "now", 1, true, true),
    Dm("Claude Code · cmux", "Run the iOS kit tests on the fleet Mac before pushing?", "2m", 1, true, true),
    Dm("Codex · cmux-platform", "Migrated device registry to Hyperdrive. Tests green.", "11m", 0, true, false),
    Dm("Claude Code · cmux-next-android", "Emulator screenshots are in the thread.", "18m", 0, true, true),
    Dm("Austin", "can you look at the sidebar PR?", "1h", 0, false, true),
    Dm("Sarah", "shipped the Expo build", "3h", 0, false, false),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Shell(start: String?) {
    var tab by remember { mutableStateOf(Tab.entries.firstOrNull { it.name.equals(start, true) } ?: Tab.Home) }
    var chat by remember { mutableStateOf<String?>(if (start == "chat") "Chief" else null) }
    if (chat != null) { ChatScreen(chat!!) { chat = null }; return }
    Scaffold(
        containerColor = Cmux.bg,
        topBar = {
            if (tab != Tab.Search) TopAppBar(
                title = { Text(if (tab == Tab.Home) "Manaflow" else tab.label, fontWeight = FontWeight.Bold, fontSize = 24.sp) },
                navigationIcon = { TeamBadge() },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Cmux.bg, titleContentColor = Cmux.text),
            )
        },
        floatingActionButton = {
            if (tab == Tab.Home || tab == Tab.DMs) FloatingActionButton({}, containerColor = Cmux.accent, contentColor = Color.White,
                shape = RoundedCornerShape(16.dp)) { Icon(Icons.Filled.Edit, "New") }
        },
        bottomBar = {
            NavigationBar(containerColor = Cmux.surface) {
                Tab.entries.forEach { t ->
                    NavigationBarItem(selected = t == tab, onClick = { tab = t }, icon = {
                        val n = when (t) { Tab.DMs -> "2"; Tab.Feed -> "1"; else -> null }
                        if (n != null) BadgedBox({ Badge { Text(n) } }) { Icon(t.icon, null) } else Icon(t.icon, null)
                    }, label = { Text(t.label) },
                        colors = NavigationBarItemDefaults.colors(selectedIconColor = Cmux.text, selectedTextColor = Cmux.text,
                            indicatorColor = Cmux.surface2, unselectedIconColor = Cmux.muted, unselectedTextColor = Cmux.muted))
                }
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (tab) {
                Tab.Home -> HomeScreen { chat = it }; Tab.DMs -> DmsScreen { chat = it }
                Tab.Feed -> FeedScreen(); Tab.Search -> SearchScreen(); Tab.More -> SettingsScreen()
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
fun SectionHeader(title: String) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 18.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Cmux.text, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.weight(1f))
        Icon(Icons.Filled.ExpandMore, null, tint = Cmux.muted)
    }
}

@Composable
fun Avatar(name: String, agent: Boolean, online: Boolean, size: Int = 36) {
    Box {
        Box(Modifier.size(size.dp).clip(RoundedCornerShape(8.dp)).background(if (agent) Cmux.accent else Cmux.surface2), contentAlignment = Alignment.Center) {
            if (agent) Icon(Icons.Filled.SmartToy, null, tint = Color.White, modifier = Modifier.size((size * 0.6).dp))
            else Text(name.take(1), color = Cmux.text, fontWeight = FontWeight.Bold)
        }
        Box(Modifier.align(Alignment.BottomEnd).offset(3.dp, 3.dp).size(12.dp).clip(CircleShape).background(Cmux.bg).padding(2.dp)
            .clip(CircleShape).background(if (online) Cmux.green else Cmux.muted))
    }
}

@Composable
fun HomeScreen(open: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                listOf(Icons.Filled.Notifications to "1 ask", Icons.Filled.Bookmark to "Saved", Icons.Filled.Terminal to "4 running").forEach { (ic, l) ->
                    Column(Modifier.weight(1f).clip(RoundedCornerShape(12.dp)).background(Cmux.surface).padding(12.dp)) {
                        Icon(ic, null, tint = Cmux.accent); Spacer(Modifier.height(6.dp)); Text(l, color = Cmux.text, fontSize = 14.sp)
                    }
                }
            }
        }
        item { SectionHeader("Workspaces") }
        items(mockWorkspaces) { w ->
            Row(Modifier.fillMaxWidth().clickable { open(w.agent?.let { "$it · ${w.name}" } ?: w.name) }.padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text("#", color = Cmux.muted, fontSize = 20.sp, modifier = Modifier.width(26.dp))
                Text(w.name, color = if (w.busy) Cmux.text else Cmux.muted, fontWeight = if (w.busy) FontWeight.Bold else FontWeight.Normal,
                    fontSize = 16.sp, modifier = Modifier.weight(1f))
                if (w.busy) Box(Modifier.size(8.dp).clip(CircleShape).background(Cmux.green))
            }
        }
        item { SectionHeader("Direct messages") }
        items(mockDms.take(4)) { d ->
            Row(Modifier.fillMaxWidth().clickable { open(d.name) }.padding(horizontal = 16.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatar(d.name, d.agent, d.online, 24); Spacer(Modifier.width(12.dp))
                Text(d.name, color = if (d.unread > 0) Cmux.text else Cmux.muted, fontWeight = if (d.unread > 0) FontWeight.Bold else FontWeight.Normal,
                    fontSize = 16.sp, modifier = Modifier.weight(1f))
                if (d.unread > 0) Box(Modifier.clip(CircleShape).background(Color(0xFFE01E5A)).padding(horizontal = 7.dp, vertical = 1.dp)) {
                    Text("${d.unread}", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold) }
            }
        }
        item { SectionHeader("Macs") }
        items(listOf("Lawrence's MacBook Pro" to true, "mini-cmuxs-mac-mini-2" to true)) { (m, on) ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Laptop, null, tint = Cmux.muted, modifier = Modifier.width(26.dp))
                Text(m, color = Cmux.muted, fontSize = 16.sp, modifier = Modifier.weight(1f))
                Box(Modifier.size(8.dp).clip(CircleShape).background(if (on) Cmux.green else Cmux.muted))
            }
        }
        item { Spacer(Modifier.height(80.dp)) }
    }
}

@Composable
fun DmsScreen(open: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize()) {
        items(mockDms) { d ->
            Row(Modifier.fillMaxWidth().clickable { open(d.name) }.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Avatar(d.name, d.agent, d.online, 40); Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row {
                        Text(d.name, color = Cmux.text, fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f), maxLines = 1)
                        Text(d.ago, color = Cmux.muted, fontSize = 13.sp)
                    }
                    Text(d.last, color = if (d.unread > 0) Cmux.text else Cmux.muted, fontSize = 14.sp, maxLines = 2)
                }
            }
        }
    }
}

@Composable
fun SearchScreen() {
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Cmux.surface2).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Search, null, tint = Cmux.muted); Spacer(Modifier.width(10.dp))
            Text("Search workspaces, agents, terminals", color = Cmux.muted)
        }
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("Workspaces", "Agents", "Terminal output", "Files").forEach {
                Text(it, color = Cmux.text, fontSize = 13.sp, modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(Cmux.surface).padding(horizontal = 10.dp, vertical = 6.dp))
            }
        }
        Spacer(Modifier.height(20.dp))
        Text("Recent searches", color = Cmux.muted, fontWeight = FontWeight.Bold, fontSize = 13.sp)
        listOf("pre-push hook", "feat-cmux-next", "emulator screenshot", "WireGuard").forEach {
            Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.History, null, tint = Cmux.muted); Spacer(Modifier.width(12.dp)); Text(it, color = Cmux.text)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(name: String, back: () -> Unit) {
    Scaffold(containerColor = Cmux.bg, topBar = {
        TopAppBar(title = { Text(name, fontWeight = FontWeight.Bold, fontSize = 18.sp) },
            navigationIcon = { IconButton(back) { Icon(Icons.Filled.ArrowBack, "Back") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Cmux.bg, titleContentColor = Cmux.text, navigationIconContentColor = Cmux.text))
    }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize().imePadding().padding(16.dp)) {
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item { Bubble("What's running on my Macs right now?", mine = true) }
                item { Bubble("Two agents are working: Claude Code in cmux (feat-cmux-next) is waiting on your answer about the iOS kit tests, and Claude Code in cmux-next-android is building the emulator APK. Codex in cmux-platform finished 11 minutes ago.", mine = false) }
            }
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Cmux.surface2).padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text("Message $name", color = Cmux.muted, modifier = Modifier.weight(1f))
                Icon(Icons.Filled.ArrowUpward, null, tint = Color.Black, modifier = Modifier.size(28.dp).clip(CircleShape).background(Cmux.text).padding(4.dp))
            }
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
