import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHome
@testable import CmuxNextLayout
import Foundation
import Testing

/// The Chief panel on the real app and daemon (user 2026-11-06): Show/Hide Chief (Cmd-I) in a workspace that is not
/// Home shows the real Chief (Home's Chief tab's own view) floating over it, never docked and never Home's other
/// panes, and hides it again; in Home, where the Chief already is, it shows nothing over Home.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChiefDockAppTests {
    @Test func cmdIShowsTheRealChiefFloatingAndHidesIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            try #require(!services.home.dock.isClassic, "the docked Home is the default")
            let window = try #require(services.windows.active)
            services.home.ensureHomeWorkspace(connection)
            try await PasswordManagerRouteTests.until({ services.windowHomes.home(in: window.state.id) != nil }, within: .seconds(60),
                                                       report: { services.home.homeWorkspaceStep })
            let home = try #require(services.windowHomes.home(in: window.state.id))
            let other = try #require(await services.windows.createWorkspace(into: window.state.id))
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == other })
            #expect(!window.frameChiefPanelShown, "a new workspace showed the Chief")

            #expect(services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ window.frameChiefPanelShown }, report: {
                "open \(window.state.chiefPanel.isOpen), shown \(window.state.workspaceID ?? "-"), home \(window.frameHome ?? "-")"
            })
            #expect(window.chiefPanelView?.chief is HomeHostView, "the panel does not hold the real Chief view")
            #expect(window.state.chiefPanel.dockedEdge == nil && window.state.docks.isEmpty, "Cmd-I docked")
            try Self.expectEmptySpaceDrags(window)
            #expect(window.state.workspaceID == other && window.parked[home.id]?.contentView.isHiddenOrHasHiddenAncestor != false,
                    "Home came on screen with the Chief")

            #expect(services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user)))
            #expect(!window.frameChiefPanelShown, "Cmd-I did not hide the Chief")

            // In Home: no panel over it.
            services.windows.show(workspaceID: home.id, in: window.state, from: .thisWindow)
            try await PasswordManagerRouteTests.until({ window.state.workspaceID == home.id })
            _ = services.registry.perform("home.openChiefDock", invocation: ActionInvocation(origin: .user))
            #expect(!window.frameChiefPanelShown, "the Chief showed over Home")
        }
    }

    /// The real chat in the Chief's own window (user 2026-11-09): a drag on the transcript's empty space moves the
    /// window, a drag in the message box does not (its text selects).
    static func expectEmptySpaceDrags(_ window: WindowController) throws {
        let panel = try #require(window.chiefPanelView), launcher = try #require(panel.launcher)
        try #require(panel.window === launcher, "the real Chief is not in its own window")
        let content = try #require(launcher.contentView), frameView = try #require(content.superview)
        content.layoutSubtreeIfNeeded()
        var empty: NSPoint?
        let b = content.bounds
        scan: for y in stride(from: b.maxY - 60, to: b.minY + 100, by: -8) {
            for x in stride(from: b.minX + 20, to: b.maxX - 20, by: 8) {
                let point = content.convert(NSPoint(x: x, y: y), to: nil)
                guard let hit = frameView.hitTest(frameView.convert(point, from: nil)),
                      hit.enclosing(HomeNativeTranscriptView.self) != nil,
                      ChiefLauncherPanel.pressMovesWindow(at: point, hit: hit, in: content) else { continue }
                empty = point
                break scan
            }
        }
        let start = try #require(empty, "no point of the real transcript moves the window")
        let hit = try #require(frameView.hitTest(frameView.convert(start, from: nil)))
        let origin = launcher.frame.origin
        try ChiefLauncherWindowTests.drag(at: hit.convert(start, from: nil), in: hit, by: CGVector(dx: 40, dy: -30))
        #expect(abs(launcher.frame.minX - (origin.x + 40)) <= 1 && abs(launcher.frame.minY - (origin.y - 30)) <= 1,
                "a drag on the real transcript's empty space (\(type(of: hit))) did not move the window: \(launcher.frame)")
        if let field = launcher.firstResponder as? NSTextView {
            let moved = launcher.frame
            try ChiefLauncherWindowTests.drag(at: NSPoint(x: field.bounds.midX, y: field.bounds.midY), in: field, by: CGVector(dx: 40, dy: 0))
            #expect(launcher.frame == moved, "a drag in the message box moved the window")
        }
    }
}

private extension NSView {
    func enclosing<T: NSView>(_ type: T.Type) -> T? {
        var view: NSView? = self
        while let next = view { if let found = next as? T { return found }; view = next.superview }
        return nil
    }
}
