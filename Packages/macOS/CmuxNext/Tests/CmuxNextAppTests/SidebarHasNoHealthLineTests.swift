import AppKit
@testable import CmuxNextApp
import CmuxNextControl
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/51772 (Austin, 2026-11-22: "Agent chat needs repair" at the sidebar's
/// bottom-left, "i dont like that at all. let's get rid of that"); Leo, 2026-11-22, ask-eacfb2ec1f: "we dont need it.
/// ever." The sidebar never shows app health: a part that is stuck, repairing or out of repairs is repaired quietly
/// (the model's ladder, then a retry once its window lets go), and the window draws no line, dot or badge for it.
/// The native card opens only when the person asks (the Restoring sessions card's Details).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHasNoHealthLineTests {
    static let linked = AppHealth().isModelLinked
    /// A label no other view in the window has, so any text that names the part is app health's line.
    static let label = "Agent chat 51772"

    @Test(.enabled(if: linked)) func aStuckPartPutsNothingInTheWindow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self,
                                                from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1"),
        ])
        tree.personal = PersonalState(workspaces: [
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0),
        ])
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"no-health-line","workspace_key":"k1"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = ["k1"]
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)

        // A part the model calls stuck at once: the page host failing two loads in its window.
        let health = services.healthFeeds.health
        health.register(AppHealth.pageHostID, kind: .pageHost, label: Self.label)
        health.event(AppHealth.pageHostID, .loadFailed)
        health.event(AppHealth.pageHostID, .loadFailed)
        let headline = try #require(health.headline, "the part is not quiet, so the old sidebar drew a line for it")
        #expect(headline.partID == AppHealth.pageHostID)

        // Main-actor hops the old indicator took to follow the snapshot.
        for _ in 0..<8 { await Task.yield() }
        window.contentView?.layoutSubtreeIfNeeded()

        let root = try #require(window.contentView)
        let healthViews = Self.views(under: root).filter { String(describing: type(of: $0)).contains("Health") }
        #expect(healthViews.isEmpty, "no app health view in the window: \(healthViews.map { type(of: $0) })")
        let named = Self.views(under: root).compactMap(Self.text).filter { $0.contains(Self.label) }
        #expect(named.isEmpty, "nothing in the window names the stuck part: \(named)")
    }

    static func views(under view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(under: $0) }
    }

    /// What a view shows or reads out.
    static func text(_ view: NSView) -> String? {
        let shown = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
        let spoken = view.accessibilityLabel() ?? ""
        let tip = view.toolTip ?? ""
        let all = [shown, spoken, tip].filter { !$0.isEmpty }.joined(separator: " | ")
        return all.isEmpty ? nil : all
    }
}
