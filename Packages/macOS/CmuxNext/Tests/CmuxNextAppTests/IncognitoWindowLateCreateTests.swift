import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// #30965 review: New Incognito Window makes an ephemeral workspace with `workspace.create`, whose terminal the daemon
/// starts before it answers. A create that gave up on its client deadline while a busy daemon still made the workspace
/// only logged the error: the person saw no page, and the daemon's workspace opened as an incognito window showing a
/// terminal. The window must open once, with the page asked for, and no terminal.
///
/// The app runs on a same-tree cmux-tui through a scripted proxy on its socket (``Proxy``), which drops the daemon's
/// answers to `workspace.create` as the mode says: the daemon still makes the workspace, and its events still reach the
/// app. Only a create the app sends again (the daemon replays it under its idempotency key) can be answered.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct IncognitoWindowLateCreateTests {
    /// A proxy between the app and the daemon's socket. `first`: the answer to the first `workspace.create` never comes
    /// (it is held until the app sends the create again, which is answered). `all`: no `workspace.create` is ever
    /// answered. `requests`: no `workspace.create` reaches the daemon.
    nonisolated enum Proxy: String {
        case first, all, requests

        static let script = #"""
        import json, socket, sys, threading
        path, mode = sys.argv[1], sys.argv[2]
        daemon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        daemon.connect(path)
        print('{"ok":true}', file=sys.stderr, flush=True)
        lock, dropped, creates = threading.Lock(), set(), [0]
        def to_daemon():
            for line in sys.stdin.buffer:
                try:
                    frame = json.loads(line)
                except ValueError:
                    frame = {}
                if isinstance(frame, dict) and frame.get('operation') == 'workspace.create':
                    with lock:
                        creates[0] += 1
                        if mode == 'requests':
                            continue
                        if mode == 'all' or creates[0] == 1:
                            dropped.add(str(frame.get('id')))
                daemon.sendall(line)
            daemon.shutdown(socket.SHUT_WR)
        threading.Thread(target=to_daemon, daemon=True).start()
        for line in daemon.makefile('rb'):
            try:
                frame = json.loads(line)
            except ValueError:
                frame = {}
            if isinstance(frame, dict) and frame.get('protocol') and str(frame.get('id')) in dropped:
                continue
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        """#

        var bridge: @Sendable (String) -> DaemonBridge {
            let mode = rawValue, script = Self.script
            return { path in DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, path, mode]) }
        }
    }

    @Test func anIncognitoWindowWhoseCreateIsAnsweredLateOpensOnceWithItsPage() async throws {
        try await PinnedPageTests.withApp(bridge: Proxy.first.bridge) { services, _ in
            let url = try #require(URL(string: "https://incognito-\(UUID().uuidString.prefix(6).lowercased()).example/"))
            let window = services.windows.newIncognitoWindow(url: url)
            try await PinnedPageTests.until({ Self.showsPage(url, window, services) }, within: .seconds(30), report: {
                "the window shows \(Self.tabs(window, services).map { ($0.kind, services.cache.browserTabs.lastURL(for: $0)) }); incognito windows \(Self.incognitoWindows(services))"
            })
            try await PinnedPageTests.until({ !Self.tabs(window, services).contains { $0.kind == .pty } }, report: { "its terminal tab stayed" })
            #expect(Self.incognitoWindows(services) == [window], "a second incognito window opened")
        }
    }

    /// Whether window `window` shows a browser tab on `url`. An incognito tab's page is kept in app memory only
    /// (its daemon record says `about:blank`, `BrowserTabService.incognitoPlaceholderURL`).
    static func showsPage(_ url: URL, _ window: String, _ services: AppServices) -> Bool {
        tabs(window, services).contains { $0.kind == .browser && services.cache.browserTabs.lastURL(for: $0) == url.absoluteString }
    }

    /// The tabs of the workspaces window `window` lists.
    static func tabs(_ window: String, _ services: AppServices) -> [TabModel] {
        services.windows.registry.members(of: window).compactMap { services.daemon.store.workspace(id: $0) }
            .flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
    }

    /// The incognito windows that list a workspace.
    static func incognitoWindows(_ services: AppServices) -> [String] {
        services.windows.registry.value.windows.map(\.id)
            .filter { services.windows.isIncognito(window: $0) && !services.windows.registry.members(of: $0).isEmpty }
    }
}
