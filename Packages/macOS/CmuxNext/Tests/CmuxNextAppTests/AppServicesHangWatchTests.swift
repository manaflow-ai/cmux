import CmuxNextCompat
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextTerminal
@testable import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// The App's hang watch reaches every site task 017 watches (plans/cmux-next/chrome-parity/p02-threads.md):
/// the BackgroundWork lanes, the daemon connections and terminal attachments the local service opens,
/// and each terminal's output lane, with a real Ghostty surface fed one chunk.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct AppServicesHangWatchTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])])
    }

    @Test func theAppsHangWatchReachesEveryWatchedLane() async throws {
        let hangs = AppHangWatch()
        let services = AppServices(environment: AppEnvironment.current([:]), hangWatch: hangs)

        // BackgroundWork: its three lanes, and an item runs in its lane's scope (other lanes' items may be open too).
        #expect(Set(hangs.lanes).isSuperset(of: ["lane.files", "lane.system", "lane.cpu"]))
        let inside = try await services.work.run(.userVisible, mayBlock: .files) { () throws -> [String] in hangs.openNames }
        #expect(inside.contains("lane.files"))

        // The daemon: every connection's LineTransport and every terminal attachment take the service's.
        #expect((services.daemon.hangWatch as? AppHangWatch) === hangs)
        let local = DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false,
                                                     installKey: .noKey, echoesPlacementShift: false, hangWatch: hangs)
        #expect((local.hangWatch as? AppHangWatch) === hangs)

        // A terminal: its output lane registers and parses each chunk in a `terminal.feed` scope.
        let store = services.daemon.store
        store.applyProvisional(snapshot: Self.tree())
        let io = ScriptedTerminalIO()
        let session = services.cache.makeSession(io: io, tab: try #require(store.tab(surface: 1)), daemon: services.daemon)
        defer { session.close(); io.finish() }
        #expect(hangs.lanes.contains("terminal.feed"))
        var entered = hangs.entries.makeAsyncIterator()
        io.send(.output(Data("watched\r\n".utf8)))
        var feed: AppHangWatch.Scope?
        while let scope = await entered.next() {
            if scope.name == "terminal.feed" { feed = scope; break }
        }
        #expect(feed == AppHangWatch.Scope(name: "terminal.feed", deadline: .milliseconds(100)))
    }
}

/// A HangWatchScoping that records every lane and each scope as it opens (any thread).
final class AppHangWatch: HangWatchScoping {
    struct Scope: Equatable, Sendable {
        var name: String
        var deadline: Duration
    }

    private struct State {
        var lanes: [String] = []
        var open: [Scope] = []
    }

    private let state = Mutex(State())
    /// Each scope as it opens.
    let entries: AsyncStream<Scope>
    private let entering: AsyncStream<Scope>.Continuation

    init() {
        (entries, entering) = AsyncStream.makeStream(of: Scope.self)
    }

    var lanes: [String] { state.withLock { $0.lanes } }
    var openNames: [String] { state.withLock { $0.open.map(\.name) } }

    func registerLane(_ name: StaticString) -> HangWatch.Registration {
        state.withLock { state in
            state.lanes.append(name.description)
            return HangWatch.Registration(slot: UInt32(state.lanes.count - 1), generation: 1)
        }
    }

    func unregister(_ registration: HangWatch.Registration) {}

    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        let scope = state.withLock { state in
            let scope = Scope(name: state.lanes[Int(registration.slot)], deadline: deadline)
            state.open.append(scope)
            return scope
        }
        entering.yield(scope)
        defer {
            state.withLock { state in
                if let index = state.open.firstIndex(of: scope) { state.open.remove(at: index) }
            }
        }
        return try body()
    }
}
