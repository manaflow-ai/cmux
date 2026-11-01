import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// An incognito window's notifications never leave the Mac (leo-workspace design/spaces.md "Incognito": nothing
/// of the window is kept or shown outside it; #31210): the feed handoff, which is what puts an item in the
/// person's Feed and pushes it to their iPhone, keeps an incognito workspace's items local. A normal
/// workspace's items still hand off.
@MainActor @Suite(.serialized)
struct IncognitoFeedHandoffTests {
    /// The handoff policy of a notification service over one normal workspace (`ws_normal`, terminal
    /// `term_normal`) and one incognito window's workspace (`ws_secret`, terminal `term_secret`). `closed`: the
    /// incognito workspace then closes (gone from the tree and the window), as when its window closes while one of
    /// its items is still handing off.
    func policy(closed: Bool = false) throws -> FeedHandoffPolicy {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let window = services.windows.newIncognitoWindow()
        let secret = WorkspaceKey(rawValue: try #require(services.windows.pendingClaims.first { $0.value == window }?.key))
        let normalTab = TabSnapshot(surface: 1, terminalResourceID: "term_normal", name: "normal")
        let secretTab = TabSnapshot(surface: 2, terminalResourceID: "term_secret", name: "deploy keys")
        let normalScreen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [normalTab])])
        let secretScreen = ScreenSnapshot(id: 2, layout: .leaf(2), panes: [PaneSnapshot(id: 2, tabs: [secretTab])])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: .generate(), resourceID: "ws_normal", name: "normal", screens: [normalScreen]),
            WorkspaceSnapshot(id: 2, key: secret, resourceID: "ws_secret", name: "secret-project", screens: [secretScreen]),
        ]))
        let service = NotificationCenterService()
        service.services = services
        let open = service.feedHandoffPolicy()
        guard closed else { return open }
        services.windows.pendingClaims[secret.rawValue] = nil
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: .generate(), resourceID: "ws_normal", name: "normal", screens: [normalScreen]),
        ]))
        #expect(!services.windows.isIncognito(workspace: secret.rawValue), "the test's incognito workspace never closed")
        return service.feedHandoffPolicy()
    }

    static func item(workspace: String?, terminal: String?) -> FeedLocalItem {
        FeedLocalItem(id: "item_\(workspace ?? terminal ?? "-")", dedupeKey: "k", title: "Claude finished",
                      body: "Rotated the production signing key.", source: "agent",
                      context: .init(workspace: workspace, terminal: terminal),
                      createdAtMs: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    @Test func anIncognitoWorkspacesItemNeverReachesTheFeedOrThePhone() throws {
        let policy = try policy()
        #expect(policy.content(for: Self.item(workspace: "ws_secret", terminal: "term_secret")) == nil,
                "an incognito window's notification was handed to the Feed and the iPhone push")
        #expect(policy.content(for: Self.item(workspace: nil, terminal: "term_secret")) == nil,
                "an incognito terminal's notification with no workspace context was handed off")
        let frozen = policy.frozenContent(for: Self.item(workspace: "ws_secret", terminal: "term_secret"))
        #expect(frozen.title.isEmpty && frozen.body.isEmpty, "an incognito item already handing off kept its text: \(frozen)")
    }

    @Test func anIncognitoItemStaysLocalAfterItsWindowCloses() throws {
        let policy = try policy(closed: true)
        #expect(policy.content(for: Self.item(workspace: "ws_secret", terminal: nil)) == nil,
                "a closed incognito window's item was handed to the Feed and the iPhone push")
        let frozen = policy.frozenContent(for: Self.item(workspace: "ws_secret", terminal: nil))
        #expect(frozen.title.isEmpty && frozen.body.isEmpty)
        #expect(policy.content(for: Self.item(workspace: nil, terminal: "term_secret")) == nil)
    }

    /// An item whose workspace the app has not classified (not in the tree yet, or left by a crashed run while it
    /// was handing off) may be an incognito window's: it waits, and a frozen one sends no text.
    @Test func anUnclassifiedWorkspacesItemWaits() throws {
        let policy = try policy()
        #expect(policy.content(for: Self.item(workspace: "ws_unknown", terminal: "term_unknown")) == nil)
        let frozen = policy.frozenContent(for: Self.item(workspace: "ws_unknown", terminal: nil))
        #expect(frozen.title.isEmpty && frozen.body.isEmpty, "an unclassified item handing off sent its text: \(frozen)")
        // Before the windows restored (a crashed run's incognito workspace not flagged yet), no pass runs.
        #expect(!policy.classified, "the handoff ran before the app knew which workspaces are incognito")
        // An item with no context (`notify --workspace` with no tab) may be an incognito workspace's too.
        #expect(policy.content(for: Self.item(workspace: nil, terminal: nil)) == nil)
    }

    @Test func aNormalWorkspacesItemStillHandsOff() throws {
        let policy = try policy()
        let content = policy.content(for: Self.item(workspace: "ws_normal", terminal: "term_normal"))
        #expect(content?.title == "Claude finished")
        #expect(content?.body == "Rotated the production signing key.")
    }
}
