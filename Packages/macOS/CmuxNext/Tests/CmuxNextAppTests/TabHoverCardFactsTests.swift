import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextResources
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-10-14: the tab hover card was not useful. Like a browser's tab preview it says
/// how much memory the tab uses ("Memory 106 MB"), and what a tab is doing: a hibernated page
/// says so, and an agent chat says its state, for how long, and its model. Each test builds
/// the tab from daemon and acpmux records, as the app does, and reads the card's lines.
@MainActor
struct TabHoverCardFactsTests {
    static let host = "install:hover-facts"

    /// The card's lines for `item` with `report` as its last sample.
    private func lines(_ item: TabItem, report: ResourceReport?) -> [String] {
        let card = TabHoverCardView(iconCaches: TabIconCaches())
        card.configure(.tab(item))
        card.setResources(report)
        return card.reportedLines
    }

    /// One sample of one tab using `megabytes` of memory.
    private func report(_ id: String, kind: TabResourceKind, megabytes: UInt64) -> ResourceReport {
        let usage = ResourceUsage(cpu: 0.01, memoryBytes: megabytes << 20)
        return ResourceReport(tabs: [TabResourceReport(id: id, title: "", kind: kind, usage: usage, processCount: 1,
                                                       sharedWithTabs: 0, available: true)],
                              total: usage, processCount: 1)
    }

    private func browserItem() -> TabItem {
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, title: "cmux docs",
                                       url: "https://cmux.com/docs/getting-started", browserEngine: "cef"))
        return TabItemMapping.shared.item(tab, fallbackTitle: "New Tab")
    }

    @Test func aBrowserTabsCardShowsItsHostAndMemory() {
        let item = browserItem()
        let shown = lines(item, report: report(item.id.rawValue, kind: .chromium, megabytes: 106))
        #expect(shown.contains("cmux.com"), "the page's host, not its full address: \(shown)")
        #expect(shown.contains("Memory \(ResourceFormat.memory(106 << 20))"), "Chrome-style memory line: \(shown)")
        #expect(!shown.contains { $0.hasPrefix("CPU") }, "a quiet page's CPU is noise: \(shown)")
    }

    @Test func aHibernatedBrowserTabsCardSaysSoInsteadOfMemory() {
        var item = browserItem()
        item.isDormant = true
        // The last sample before it hibernated is what hibernating freed.
        let shown = lines(item, report: report(item.id.rawValue, kind: .chromium, megabytes: 180))
        let line = shown.first { $0.hasPrefix("Hibernated") }
        #expect(line != nil, "a hibernated page says so: \(shown)")
        // What it was using before, never a claim about what hibernating freed.
        #expect(line == "Hibernated · was using \(ResourceFormat.memory(180 << 20))", "what it was using: \(shown)")
        #expect(!shown.contains { $0.hasPrefix("Memory") }, "no live memory line for a page that is not loaded: \(shown)")
    }

    @Test func aHibernatedPageWithNoMeasuredSampleSaysOnlyHibernated() {
        var item = browserItem()
        item.isDormant = true
        var zero = report(item.id.rawValue, kind: .chromium, megabytes: 0)
        zero.tabs[0].processCount = 0
        #expect(lines(item, report: zero).last == "Hibernated", "no number from a sample that measured nothing")
    }

    /// The card reads its own tab's row, wherever it is in the report.
    @Test func theMemoryRowIsTheTabsOwn() {
        let item = browserItem()
        var both = report("some-other-tab", kind: .chromium, megabytes: 900)
        both.tabs += report(item.id.rawValue, kind: .chromium, megabytes: 106).tabs
        let shown = lines(item, report: both)
        #expect(shown.contains("Memory \(ResourceFormat.memory(106 << 20))"), "another tab's memory: \(shown)")
    }

    /// A terminal its daemon did not report has only the app-side Ghostty estimate: that is
    /// not its memory, so no row.
    @Test func aTerminalWithNoMeasuredProcessShowsNoMemory() {
        var item = TabItem(id: TabID("term-unmeasured"), title: "zsh", subtitle: "~/Projects/site")
        item.hover = TabHoverFacts(kind: .terminal)
        var estimate = report(item.id.rawValue, kind: .terminal, megabytes: 30)
        estimate.tabs[0].processCount = 0
        let shown = lines(item, report: estimate)
        #expect(!shown.contains { $0.hasPrefix("Memory") }, "the Ghostty estimate shown as the terminal's memory: \(shown)")
    }

    /// A running command is the tab's title already: its card says Running and for how long.
    @Test func aRunningTerminalSaysRunningAndForHowLong() {
        var item = TabItem(id: TabID("term-running"), title: "cargo build", subtitle: "~/Projects/site")
        item.hover = TabHoverFacts(kind: .terminal, activity: .running, since: Date().addingTimeInterval(-12))
        let shown = lines(item, report: nil)
        #expect(shown.contains("Running · 12s") || shown.contains("Running · 13s"), "the running time: \(shown)")
        #expect(shown.filter { $0.contains("cargo build") }.count == 1, "the command repeated under the title: \(shown)")
    }

    /// A terminal tab built from a `session.events` snapshot whose terminal record carries
    /// `extra`, as the app maps it.
    private func terminalItem(extra: String) throws -> TabItem {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":\#(extra)}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        let tab = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        return TabItemMapping.shared.item(tab, fallbackTitle: "zsh")
    }

    /// The daemon's ms clock `seconds` ago, as its records write it.
    private func ms(_ seconds: TimeInterval) -> String { String(UInt64(Date().addingTimeInterval(-seconds).timeIntervalSince1970 * 1000)) }

    /// Leo 2026-10-21: "the tab hover card shows 'Idle · 5m' or 'Output · 12s' for a plain shell at
    /// its prompt." Output under a minute old reads as Output, with a quiet dot, never working.
    @Test func aShellAtItsPromptThatJustPrintedSaysOutput() throws {
        let item = try terminalItem(extra: #"{"prompt":{"since_ms":"\#(ms(30))"},"last_output":{"at_ms":"\#(ms(12))"}}"#)
        let shown = lines(item, report: nil)
        #expect(shown.contains("Output · 12s") || shown.contains("Output · 13s"), "how long ago it printed: \(shown)")
        #expect(TabHoverCardLines.tone(item) == .secondary, "a shell at its prompt is quiet")
    }

    @Test func aShellAtItsPromptThatPrintedLongAgoSaysIdle() throws {
        let item = try terminalItem(extra: #"{"prompt":{"since_ms":"\#(ms(600))"},"last_output":{"at_ms":"\#(ms(300))"}}"#)
        let shown = lines(item, report: nil)
        #expect(shown.contains("Idle · 5m"), "how long it has been quiet: \(shown)")
        #expect(TabHoverCardLines.tone(item) == .secondary)
    }

    /// Before its first output after the daemon starts or adopts it, a shell at its prompt has no
    /// last output yet: it has been quiet since its prompt printed.
    @Test func aShellAtItsPromptWithNoOutputYetSaysIdleSinceItsPrompt() throws {
        let item = try terminalItem(extra: #"{"prompt":{"since_ms":"\#(ms(300))"}}"#)
        let shown = lines(item, report: nil)
        #expect(shown.contains("Idle · 5m"), "quiet since its prompt: \(shown)")
        #expect(TabHoverCardLines.tone(item) == .secondary)
    }

    /// A daemon whose clock runs ahead names a prompt in this Mac's future: it counts from when this
    /// Mac saw it, so two minutes on the shell reads as quiet, not as output that never ages.
    @Test func aPromptFromADaemonAheadCountsFromWhenItArrived() throws {
        let item = try terminalItem(extra: #"{"prompt":{"since_ms":"\#(ms(-600))"}}"#)
        let later = TabHoverCardLines.make(item, report: nil, now: Date().addingTimeInterval(120))
        #expect(later.status == "Idle · 2m", "counted from its arrival: \(String(describing: later.status))")
    }

    /// With no shell integration the daemon sends no prompt: no claim that the shell is idle.
    @Test func aTerminalWithNoPromptRecordSaysNothingAboutOutput() throws {
        let item = try terminalItem(extra: #"{"last_output":{"at_ms":"\#(ms(12))"}}"#)
        let shown = lines(item, report: nil)
        #expect(!shown.contains { $0.hasPrefix("Output") || $0.hasPrefix("Idle") }, "no prompt, no output row: \(shown)")
        #expect(TabHoverCardLines.tone(item) == nil)
    }

    /// A running command keeps its Running row, whatever it printed.
    @Test func aRunningCommandStillSaysRunning() throws {
        let item = try terminalItem(extra: #"{"busy":{"since_ms":"\#(ms(12))"},"last_output":{"at_ms":"\#(ms(1))"}}"#)
        let shown = lines(item, report: nil)
        #expect(shown.contains("Running · 12s") || shown.contains("Running · 13s"), "the running time: \(shown)")
        #expect(!shown.contains { $0.hasPrefix("Output") }, "\(shown)")
    }

    /// A local file's place is its path from home, like the rest of cmux.
    @Test func aLocalFilesPlaceUsesTheTildeForm() {
        let path = NSHomeDirectory() + "/Docs/notes.html"
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 9), kind: .browser, title: "notes",
                                       url: URL(fileURLWithPath: path).absoluteString, browserEngine: "cef"))
        let shown = lines(TabItemMapping.shared.item(tab, fallbackTitle: "New Tab"), report: nil)
        #expect(shown.contains("~/Docs/notes.html"), "the file's path from home: \(shown)")
    }

    @Test func anAgentChatsCardShowsItsStateForHowLongAndItsModel() throws {
        let started = UInt64(Date().addingTimeInterval(-185).timeIntervalSince1970 * 1000)
        let summary: [String: Any] = [
            "sessionId": "s-facts", "status": "running", "indicator": "working", "model": "Opus 5.5",
            "cwd": "/Users/someone/Projects/site", "turn": ["startedAt": started, "prompt": "fix the build"],
            "lane": ["state": "working", "since": started],
        ]
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        turns.apply(session: "s-facts", state: nil, lastMessage: nil, muted: false, title: nil,
                    detail: try #require(AgentChatDetail.of(summary: summary)))
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: 8), kind: .conversation, title: "Fix the build")
        snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s-facts", harness: "claude"))
        let item = TabItemMapping.shared.item(TabModel(snapshot), fallbackTitle: "Agent", turns: turns)
        let shown = lines(item, report: report(item.id.rawValue, kind: .webkit, megabytes: 46))
        let status = shown.first { $0.contains("Opus 5.5") }
        #expect(status?.contains("Working") == true, "the chat's state: \(shown)")
        #expect(status?.contains("3m") == true, "how long it has been working: \(shown)")
        #expect(shown.contains("~/Projects/site") || shown.contains { $0.hasSuffix("Projects/site") }, "its folder: \(shown)")
        #expect(shown.contains("Memory \(ResourceFormat.memory(46 << 20))"), "the chat page's memory: \(shown)")
    }
}
