import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// cmux#26695 (nightly): "after making splits or new browsers, they disappear suddenly; workspace
/// left empty." Split Right, Split Down and Split Browser Right pressed as a person at key-repeat
/// speed, each press before the daemon answers the last, on the real same-tree daemon. Every pane a
/// press made stays in the window and in the store once the daemon answered all of them: the count
/// never drops below the peak it reached, and the workspace never shows no pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RapidSplitsKeepPanesTests {
    enum Burst: String, CaseIterable, Sendable {
        case terminalSplits, browserSplits, mixed

        var actions: [ActionID] {
            switch self {
            case .terminalSplits: ["splitRight", "splitDown", "splitRight", "splitDown"]
            case .browserSplits: ["splitBrowserRight", "splitBrowserDown", "splitBrowserRight"]
            case .mixed: ["splitBrowserRight", "splitDown", "splitBrowserRight", "splitRight"]
            }
        }
    }

    @Test(arguments: Burst.allCases)
    func rapidSplitsKeepEveryPane(burst: Burst) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            window.window?.setFrame(NSRect(x: 100, y: 100, width: 1600, height: 1000), display: true)
            let screen = try #require(store.screen(containing: pane.pane.handle))
            @MainActor func shown() -> Int { services.windows.active?.workspaceContent?.panes.count ?? 0 }
            @MainActor func listed() -> Int { store.screensByHandle[screen.handle]?.panes.count ?? 0 }
            // Each sample: window panes / store panes, kept when it changes, for the failure message.
            var trace: [String] = []
            @MainActor func mark(_ step: String) {
                let entry = "\(shown())/\(listed())"
                if trace.last?.hasSuffix(" " + entry) != true { trace.append("\(step) \(entry)") }
            }
            mark("start")
            for (index, id) in burst.actions.enumerated() {
                #expect(services.registry.perform(id, invocation: ActionInvocation(origin: .user)), "\(id) did not run")
                // Key repeat: the next press comes before the daemon answers this one.
                try await Task.sleep(for: .milliseconds(30))
                mark("\(index + 1)")
            }
            let expected = 1 + burst.actions.count
            try await PasswordManagerRouteTests.until({ listed() == expected && shown() == expected },
                                                      report: { "trace \(trace)" })
            // Settled: every reply, pane-added and layout-changed has landed, then a few seconds more.
            var lowest = Int.max
            let settle = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < settle {
                mark("settle")
                lowest = min(lowest, shown(), listed())
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(lowest == expected, "a pane left after showing: lowest \(lowest) of \(expected); trace \(trace)")
            #expect(store.intentLog.isEmpty, "intents still pending: \(store.pendingIntents)")
            let daemonPanes = store.screensByHandle[screen.handle]?.panes.filter { $0.handle.rawValue < ProvisionalPane.firstHandle } ?? []
            #expect(daemonPanes.count == expected, "daemon panes \(daemonPanes.count) of \(expected); trace \(trace)")
        }
    }
}
