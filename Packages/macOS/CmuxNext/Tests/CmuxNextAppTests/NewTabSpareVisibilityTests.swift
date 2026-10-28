import AppKit
import CmuxNextDaemon
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Testing

/// A late chats.page answer invalidates the first cover after the spare has gone to sleep.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSpareVisibilityTests {
    @Test func aParkedSpareWakesForItsReplacementCoverAndSleepsAgain() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let window = try #require(services.windows.active?.window)
            window.orderFrontRegardless()
            let pool = services.newTabSpares
            defer { pool.dropAll() }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ pool.spare != nil })
            let view = try #require(pool.spare?.view), host = try #require(view.superview)
            // Native swift-test has no page compositor for this zero-opacity spare. Deliver the
            // existing pane.painted event explicitly; the lifecycle under test starts here.
            view.model.markPainted()
            try await PasswordManagerRouteTests.until({ view.isHidden })
            let frames = AgentPaneNewTabFrame.shared
            // A first-page response arrives after the initial cover was taken.
            frames.chatsAnswered(.init(chats: [], nextCursor: nil, ready: true, enabled: true, design: "visibility-regression"),
                                 query: .init(text: nil, cursor: nil, limit: 50), to: view.model)
            frames.capture(view, in: host)
            #expect(view.redraw.givesNewTabFrame)
            #expect(!view.isHidden, "the replacement cover cannot be captured from a suspended renderer")
            try await PasswordManagerRouteTests.until({ !view.redraw.givesNewTabFrame && view.isHidden })

            // Adoption during another capture invalidates its eventual sleep callback.
            frames.capture(view, in: host)
            #expect(!view.isHidden)
            let adopted = try #require(pool.take(for: window, size: view.frame.size)?.view)
            #expect(adopted === view)
            #expect(view.redraw.newTabFrameCaptureChanged == nil)
            try await PasswordManagerRouteTests.until({ !view.redraw.givesNewTabFrame })
            #expect(!view.isHidden, "a late capture hid the adopted page")
            view.close()
        }
    }
}
