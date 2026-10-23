import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// No O(all) work per event (perf-lead.md cause 6): the app pushes its device chats (on every chat
/// index change: any agent's new message), its Recently Closed list (on every tab close) and Now
/// Playing (on every track change) to every agent page it made. A chat or New Tab page in a
/// background tab or a parked workspace stays in its window, hidden (`PaneParkableContent`), and
/// each push encoded its JSON and woke its web process: one change cost every agent page of the
/// session. A page nobody can see takes no push; it gets the newest value of each once it shows.
@Suite(.serialized)
@MainActor
struct AgentPaneHiddenStatePushesTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The scripts a pane ran, by the bridge call they make.
    private final class Recorder {
        var scripts: [String] = []
        func count(_ call: String) -> Int { scripts.filter { $0.contains("cmuxAcpmuxBridge?.\(call)?.(") }.count }
        func last(_ call: String) -> String? { scripts.last { $0.contains("cmuxAcpmuxBridge?.\(call)?.(") } }
    }

    private struct Fixture {
        let window: NSWindow
        let parked: NSView
        let shown: AgentPaneView
        let hidden: [AgentPaneView]
        let recorders: [ObjectIdentifier: Recorder]
        let directory: URL

        init(hidden count: Int) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "hidden-pushes-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "index.html")
            try Data("<html><body></body></html>".utf8).write(to: file)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = content
            parked = NSView(frame: content.bounds)
            parked.isHidden = true // background tabs of a pane, a parked workspace
            content.addSubview(parked)
            func pane(in parent: NSView) throws -> AgentPaneView {
                let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
                view.frame = parent.bounds
                parent.addSubview(view)
                return view
            }
            shown = try pane(in: content)
            hidden = try (0..<count).map { _ in try pane(in: parked) }
            var recorders: [ObjectIdentifier: Recorder] = [:]
            for view in [shown] + hidden {
                let recorder = Recorder()
                view.evaluateScript = { recorder.scripts.append($0) }
                recorders[ObjectIdentifier(view)] = recorder
            }
            self.recorders = recorders
        }

        func recorder(_ view: AgentPaneView) -> Recorder { recorders[ObjectIdentifier(view)]! }
        var all: [AgentPaneView] { [shown] + hidden }
        func close() {
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func chats(_ title: String) -> [AgentPaneDeviceChat] {
        [AgentPaneDeviceChat(key: "claude-code:\(title)", harness: "claude-code", title: title,
                             updatedAt: Date(timeIntervalSince1970: 1_790_000_000))]
    }

    private static func closed(_ id: String) -> AgentPaneClosedList {
        AgentPaneClosedList([AgentPaneClosedItem(id: id, kind: .terminal, title: "zsh", detail: "~/repo",
                                                 closedAt: Date(timeIntervalSince1970: 1_790_000_000), icon: nil, isAvailable: true)])
    }

    @Test func aChangeReachesOnlyThePagesOnScreen() throws {
        let fixture = try Fixture(hidden: 12)
        defer { fixture.close() }
        // What AgentPageChats and NewTabClosed do on a chat index change and a tab close.
        for view in fixture.all { view.deviceChats = Self.chats("first") }
        for view in fixture.all { view.recentlyClosed = Self.closed("closed:1") }
        for view in fixture.all { view.deviceChats = Self.chats("second") }

        let shown = fixture.recorder(fixture.shown)
        #expect(shown.count("applyDeviceChats") == 2 && shown.count("applyRecentlyClosed") == 1, "the page on screen gets every change")
        let reached = fixture.hidden.filter { fixture.recorder($0).count("applyDeviceChats") + fixture.recorder($0).count("applyRecentlyClosed") > 0 }
        #expect(reached.isEmpty, "a chat index change and a tab close pushed to \(reached.count) agent pages nobody can see")
    }

    @Test func aHiddenPageGetsTheNewestValuesOnceWhenItShows() throws {
        let fixture = try Fixture(hidden: 4)
        defer { fixture.close() }
        for view in fixture.all { view.deviceChats = Self.chats("first") }
        for view in fixture.all { view.recentlyClosed = Self.closed("closed:1") }
        for view in fixture.all { view.deviceChats = Self.chats("second") }
        for view in fixture.all { view.recentlyClosed = Self.closed("closed:2") }

        fixture.parked.isHidden = false
        for view in fixture.hidden {
            let recorder = fixture.recorder(view)
            #expect(recorder.count("applyDeviceChats") == 1, "a page that shows gets the newest chats once")
            #expect(recorder.last("applyDeviceChats")?.contains("claude-code:second") == true)
            #expect(recorder.count("applyRecentlyClosed") == 1, "a page that shows gets the newest closed list once")
            #expect(recorder.last("applyRecentlyClosed")?.contains("closed:2") == true)
        }
        // Shown now: a change reaches it at once.
        for view in fixture.hidden { view.deviceChats = Self.chats("third") }
        #expect(fixture.hidden.allSatisfy { fixture.recorder($0).count("applyDeviceChats") == 2 })
    }

    @Test func nowPlayingReachesOnlyThePagesOnScreen() throws {
        let fixture = try Fixture(hidden: 8)
        defer { fixture.close() }
        let player = AgentPaneNowPlaying()
        for view in fixture.all { _ = player.event(for: view) } // each page's load
        player.track = AgentPaneNowPlaying.Track(title: "Song", artist: "Band", artwork: nil, isPlaying: true, position: 1, duration: 200,
                                                 rate: 1, positionDate: Date(timeIntervalSince1970: 1_790_000_000), canPrevious: true,
                                                 canNext: true, labels: [:])
        #expect(fixture.recorder(fixture.shown).count("applyNowPlaying") == 1)
        #expect(fixture.hidden.allSatisfy { fixture.recorder($0).count("applyNowPlaying") == 0 },
                "a track change pushed to agent pages nobody can see")
        fixture.parked.isHidden = false
        #expect(fixture.hidden.allSatisfy { fixture.recorder($0).last("applyNowPlaying")?.contains("Song") == true })
    }
}
