import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Lead decision on #32979 (a rapid second Cmd-T must not load cold): two Cmd-T 150 ms apart both adopt a page that
/// is already loaded, as Chrome keeps a spare renderer ready for the next navigation; and the pool makes no page in
/// either open's frames.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabRapidPairTests {
    /// Waits up to `limit` for `condition`, recording nothing when it does not come (the pool may keep fewer spares).
    static func waitFor(_ condition: () -> Bool, within limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func aRapidSecondCmdTAdoptsASpareToo() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-rapid-pair")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = FileManager.default.temporaryDirectory.appending(path: "rapid-pair-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            var made: [AgentPaneView] = []
            defer {
                pool.makeSpare = nil
                pool.dropAll()
                made.forEach { $0.close() }
                try? FileManager.default.removeItem(at: folder)
            }
            // An inert page stands in for WebKit's; it counts as loaded and drawn at once.
            pool.dropAll()
            pool.makeSpare = { page in
                let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
                model.hasHandshake = true
                model.markPainted()
                made.append(view)
                return view
            }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ pool.spare != nil }, report: { "no spare was parked" })
            // The pool fills as far as it keeps spares (one at a time, each after the one before drew).
            try await Self.waitFor({ made.count >= 2 }, within: .seconds(3))
            let before = made.count, openings = pool.openings.count

            NewTabPage.open(in: pane, seed: nil)
            try await Task.sleep(for: .milliseconds(150))
            NewTabPage.open(in: pane, seed: nil)
            try await Task.sleep(for: .milliseconds(60))

            let pair = pool.openings.dropFirst(openings).map(\.spare)
            // A cold open records a second opening (the store's tab takes no spare either): every one must be a spare.
            #expect(pair.count >= 2 && !pair.contains(false), "a Cmd-T 150 ms after the one before loaded cold (spare per opening: \(pair))")
            #expect(made.count == before, "a spare was made within the pair's frames (\(made.count - before) made)")
            // Memory pressure drops every spare (`dropAll`), the second one too.
            try await Self.waitFor({ made.count >= before + 2 }, within: .seconds(3))
            pool.dropAll()
            #expect(pool.spare == nil, "a spare stayed parked after dropAll")
        }
    }
}
