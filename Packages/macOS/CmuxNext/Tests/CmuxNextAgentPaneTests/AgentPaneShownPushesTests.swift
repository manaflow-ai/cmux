import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextPages

/// "im at 100% cpu rn" (Leo, 2026-11-03): 11% of the NIGHTLY's main thread was DevTools
/// `Runtime.evaluate` calls of the agent pages' host pushes. The Chats feed set every agent pane's
/// device chats on each change of the chat index, a few per turn while agents ran, and each pane's
/// page got its own evaluate, hidden or not. A pane's app-wide state pushes now go once per turn,
/// and a pane nobody can see gets them when it shows (``AgentPaneShownPushes``).
@Suite(.serialized)
@MainActor
struct AgentPaneShownPushesTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func view() throws -> AgentPaneView {
        _ = NSApplication.shared
        return try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
    }

    private static func chats(_ index: Int) -> [AgentPaneDeviceChat] {
        [AgentPaneDeviceChat(key: "claude-code:s-\(index)", harness: "claude-code", title: "Chat \(index)",
                             updatedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))]
    }

    private static func deviceChatScripts(_ scripts: [String]) -> [String] {
        scripts.filter { $0.contains("applyDeviceChats") }
    }

    /// A few turns of the main actor, for pushes owed to a later turn.
    private static func turns() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Red at base: each change evaluated a script in a pane out of any window.
    @Test func aPaneNobodySeesGetsNoDeviceChatPush() async throws {
        let view = try Self.view()
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        for index in 1...3 { view.deviceChats = Self.chats(index) }
        await Self.turns()

        #expect(Self.deviceChatScripts(scripts).isEmpty, "a pane in no window got \(Self.deviceChatScripts(scripts).count) device chat pushes")
    }

    @Test func changesInOneTurnSendOnePushWithTheNewest() throws {
        let view = try Self.view()
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        var later: [@MainActor () -> Void] = []
        view.shownPushes.isHidden = { _ in false }
        view.shownPushes.nextTurn = { later.append($0) }

        for index in 1...5 { view.deviceChats = Self.chats(index) }
        #expect(Self.deviceChatScripts(scripts).isEmpty, "a change pushed in its own turn")
        #expect(later.count == 1, "five changes in one turn scheduled \(later.count) flushes")
        for work in later { work() }

        let sent = Self.deviceChatScripts(scripts)
        #expect(sent.count == 1)
        #expect(sent.first?.contains("claude-code:s-5") == true, "the push did not carry the newest chats")
    }

    @Test func aHiddenPaneGetsTheNewestChatsOnceWhenItShows() throws {
        let view = try Self.view()
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        var later: [@MainActor () -> Void] = []
        var hidden = true
        // Other parts of the pane (its frame pacer) keep probes of their own.
        let probes = { view.subviews.count { $0 is AgentPaneVisibilityProbe } }
        let baseline = probes()
        view.shownPushes.isHidden = { _ in hidden }
        view.shownPushes.nextTurn = { later.append($0) }

        view.deviceChats = Self.chats(1)
        for work in later { work() }
        later.removeAll()
        for index in 2...4 { view.deviceChats = Self.chats(index) }
        #expect(later.isEmpty, "a held pane scheduled more flushes")
        #expect(Self.deviceChatScripts(scripts).isEmpty, "a hidden pane got a push")
        #expect(probes() == baseline + 1, "nothing watches for the pane to show")

        hidden = false
        // What the pane's visibility probe calls when the pane shows.
        view.shownPushes.flush(view)

        let sent = Self.deviceChatScripts(scripts)
        #expect(sent.count == 1)
        #expect(sent.first?.contains("claude-code:s-4") == true, "the shown pane did not get the newest chats")
        #expect(view.shownPushes.owedNames.isEmpty)
        #expect(probes() == baseline, "the shown pane kept its watch")
    }

    /// The harness of the PR's Performance table: 20 agent panes (one seen), the chat index changing
    /// 5 times in each of 40 turns, each script costing a fixed 0.25 ms of the main thread (a stand-in
    /// for the DevTools call). `before` replays the old fan-out (every change, every pane, at once).
    @Test(arguments: [true, false]) func harness(before: Bool) async throws {
        let panes = 20, turns = 40, changesPerTurn = 5
        let cost: TimeInterval = 0.000_25
        var evaluates = 0
        var later: [@MainActor () -> Void] = []
        var views: [AgentPaneView] = []
        for index in 0..<panes {
            let view = try Self.view()
            view.evaluateScript = { script in
                guard script.contains("applyDeviceChats") else { return }
                evaluates += 1
                let end = ProcessInfo.processInfo.systemUptime + cost
                while ProcessInfo.processInfo.systemUptime < end {}
            }
            let seen = index == 0
            view.shownPushes.isHidden = { _ in before ? false : !seen }
            view.shownPushes.nextTurn = { work in if before { work() } else { later.append(work) } }
            views.append(view)
        }
        let start = ProcessInfo.processInfo.systemUptime
        var change = 0
        for _ in 0..<turns {
            for _ in 0..<changesPerTurn {
                change += 1
                for view in views { view.deviceChats = Self.chats(change) }
            }
            let work = later
            later.removeAll()
            for flush in work { flush() }
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        print("AgentPaneShownPushes harness \(before ? "before" : "after"): \(evaluates) evaluates, \(String(format: "%.1f", elapsed)) ms main thread for \(turns * changesPerTurn) changes over \(panes) panes")
        if before {
            #expect(evaluates == panes * turns * changesPerTurn)
        } else {
            #expect(evaluates == turns, "one evaluate per turn, for the one seen pane")
        }
    }

    /// A window that says it is on screen: the real seen check (``AgentPaneFramePacer/nobodySees(_:)``)
    /// then judges only where a pane sits in it, on a CI Mac with no screen as on Leo's.
    final class ShownWindow: NSWindow {
        override var occlusionState: NSWindow.OcclusionState { .visible }
    }

    /// The four agent pages of Lawrence's report (2026-11-18: dropped frames scrolling a short chat
    /// while hidden pages shared its renderer), with the real seen check: a chat in sight, a chat
    /// and a New Tab page behind other tabs, and the prewarmed New Tab spare, painted and parked
    /// 100,000 pt off screen (``PageOffscreenParking``). Each Chats-feed change sets every page's
    /// device chats and recently closed items (AgentPageChats, NewTabClosed); each attention and
    /// Now Playing change pushes to every page that got them. Counts the push scripts each page
    /// evaluates over `changes` changes, one change per turn. Built only from what the base has, so
    /// the same test gives the before numbers at the base and the after numbers here.
    @Test func hiddenPagesEvaluateNoPushScripts() throws {
        let changes = 100
        _ = NSApplication.shared
        let window = ShownWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        let shownTab = NSView(frame: content.bounds), hiddenTabs = NSView(frame: content.bounds)
        hiddenTabs.isHidden = true
        let parking = PageOffscreenParking(frame: PageOffscreenParking.frame(in: content.bounds, size: content.bounds.size))
        for view in [shownTab, hiddenTabs, parking] { content.addSubview(view) }
        let attention = AgentPaneAttentionTabs(), nowPlaying = AgentPaneNowPlaying()
        func page(_ name: String, newTab: Bool, in parent: NSView) throws -> (String, AgentPaneView) {
            let model = AgentPaneModel(host: NoHost(), attentionTabs: attention, newTab: newTab ? AgentPaneNewTab(kind: .agent) : nil)
            let view = try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null"))))
            view.frame = parent.bounds
            parent.addSubview(view)
            return (name, view)
        }
        let pages = try [page("seen chat", newTab: false, in: shownTab), page("hidden chat", newTab: false, in: hiddenTabs),
                         page("hidden New Tab", newTab: true, in: hiddenTabs), page("parked spare", newTab: true, in: parking)]
        pages[3].1.model.markPainted()
        var later: [@MainActor () -> Void] = []
        var counts: [String: Int] = [:]
        let pushes = ["applyDeviceChats", "applyRecentlyClosed", "applyAttentionTabs", "applyNowPlaying"]
        for (name, view) in pages {
            view.shownPushes.nextTurn = { later.append($0) }
            attention.push(to: view)
            nowPlaying.push(to: view)
            view.evaluateScript = { script in if pushes.contains(where: script.contains) { counts[name, default: 0] += 1 } }
        }
        func runTurn() {
            while !later.isEmpty {
                let work = later
                later.removeAll()
                for flush in work { flush() }
            }
        }
        runTurn()
        counts = [:]
        for change in 1...changes {
            let chats = Self.chats(change)
            let closed = AgentPaneClosedList([AgentPaneClosedItem(id: "closed:\(change)", kind: .terminal, title: "zsh \(change)", detail: nil,
                                                                  closedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(change)),
                                                                  icon: nil, isAvailable: true)])
            for (_, view) in pages {
                view.deviceChats = chats
                view.recentlyClosed = closed
            }
            attention.items = [AgentPaneAttentionTabs.Item(tabId: "tab_\(change)", reason: "Look", workspaceTitle: "W", tabTitle: "T", atMs: UInt64(change))]
            nowPlaying.track = AgentPaneNowPlaying.Track(title: "Song \(change)", artist: "A", artwork: nil, isPlaying: true, position: nil, duration: nil,
                                                         rate: 1, positionDate: Date(timeIntervalSince1970: 0), canPrevious: false, canNext: false, labels: [:])
            runTurn()
        }
        let row = pages.map { "\($0.0)=\(counts[$0.0, default: 0])" }.joined(separator: " ")
        print("AgentPaneShownPushes hidden pages: push scripts over \(changes) changes: \(row)")
        #expect(counts["hidden chat", default: 0] == 0, "a chat behind another tab evaluated \(counts["hidden chat", default: 0]) push scripts")
        #expect(counts["hidden New Tab", default: 0] == 0, "a New Tab page behind another tab evaluated \(counts["hidden New Tab", default: 0]) push scripts")
        #expect(counts["parked spare", default: 0] == 0, "the painted parked spare evaluated \(counts["parked spare", default: 0]) push scripts")
        #expect(counts["seen chat", default: 0] == changes, "the seen chat gets the attention list once per change, and no New Tab data")
    }
}
