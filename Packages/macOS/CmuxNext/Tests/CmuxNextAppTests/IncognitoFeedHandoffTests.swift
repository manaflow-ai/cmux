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
        let secret = WorkspaceKey(rawValue: try #require(services.windows.claims.pending.first { $0.value == window }?.key))
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
        services.windows.claims.pending[secret.rawValue] = nil
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
        #expect(policy.frozenContent(for: Self.item(workspace: "ws_secret", terminal: "term_secret")) == nil,
                "an incognito item already handing off would still be adopted")
    }

    @Test func anIncognitoItemStaysLocalAfterItsWindowCloses() throws {
        let policy = try policy(closed: true)
        #expect(policy.content(for: Self.item(workspace: "ws_secret", terminal: nil)) == nil,
                "a closed incognito window's item was handed to the Feed and the iPhone push")
        #expect(policy.frozenContent(for: Self.item(workspace: "ws_secret", terminal: nil)) == nil)
        #expect(policy.content(for: Self.item(workspace: nil, terminal: "term_secret")) == nil)
    }

    /// An item whose workspace the app has not classified (not in the tree yet, or left by a crashed run while it
    /// was handing off) may be an incognito window's: it waits, and a frozen one is withdrawn, never adopted.
    @Test func anUnclassifiedWorkspacesItemWaits() throws {
        let policy = try policy()
        #expect(policy.content(for: Self.item(workspace: "ws_unknown", terminal: "term_unknown")) == nil)
        #expect(policy.frozenContent(for: Self.item(workspace: "ws_unknown", terminal: nil)) == nil,
                "an unclassified item handing off would be adopted")
        // Before the windows restored (a crashed run's incognito workspace not flagged yet), no pass runs.
        #expect(!policy.classified, "the handoff ran before the app knew which workspaces are incognito")
        // An item with no context (`notify --workspace` with no tab) may be an incognito workspace's too.
        #expect(policy.content(for: Self.item(workspace: nil, terminal: nil)) == nil)
    }

    /// A frozen incognito item (a crashed run froze it) is withdrawn: `feed.adopt.cancel`, never `feed.adopt`, and
    /// on `cancelled: true` the daemon takes it back (`feed-local-handoff-abort`).
    @Test func aFrozenIncognitoItemIsWithdrawnNotAdopted() async {
        final class Ops { var sent: [String] = [] }
        let ops = Ops()
        var item = Self.item(workspace: "ws_secret", terminal: "term_secret")
        item.state = .handingOff
        let frozen = item
        var driver: FeedHandoffDriver?
        let step: String = await withCheckedContinuation { finished in
            driver = FeedHandoffDriver(
                daemon: .init(serves: { true }, list: { state, _ in state == .handingOff ? [frozen] : [] },
                              begin: { _ in frozen },
                              done: { _, _ in finished.resume(returning: "done"); return frozen },
                              abort: { _ in finished.resume(returning: "abort"); return frozen }),
                owner: { _, body in
                    ops.sent.append(body["op"] as? String ?? "?")
                    return body["op"] as? String == "feed.adopt.cancel" ? ["value": ["cancelled": true]] : [:]
                },
                isSignedIn: { true }, installID: { "inst_test" },
                policy: { FeedHandoffPolicy(preferences: .init(), mutedWorkspaces: [], normalWindows: ["ws_normal"]) })
            driver?.run()
        }
        #expect(step == "abort")
        #expect(ops.sent == ["feed.adopt.cancel"], "a frozen incognito item reached the cloud: \(ops.sent)")
        _ = driver
    }

    /// A normal workspace that no window lists can be placed into an incognito window (#31309). If that happens
    /// while its item's `feed.adopt` is in flight, the adopt has already committed when the reply arrives: the
    /// driver re-checks the window after the await and withdraws the item (`feed.adopt.cancel`, which answers
    /// `cancelled: false` for a committed adopt) and archives the cloud copy, so it leaves the Feed and its
    /// pending iPhone push is cleared, before the daemon records the move.
    @Test func anItemWhoseWorkspaceMovesIntoAnIncognitoWindowDuringTheSendIsWithdrawn() async {
        final class State { var sent: [[String: Any]] = []; var normal: Set<String> = ["ws_normal", "term_normal"] }
        let state = State()
        var item = Self.item(workspace: "ws_normal", terminal: "term_normal")
        item.state = .handingOff
        let frozen = item
        var driver: FeedHandoffDriver?
        let step: String = await withCheckedContinuation { finished in
            driver = FeedHandoffDriver(
                daemon: .init(serves: { true }, list: { listed, _ in listed == .handingOff ? [frozen] : [] },
                              begin: { _ in frozen },
                              done: { _, _ in finished.resume(returning: "done"); return frozen },
                              abort: { _ in finished.resume(returning: "abort"); return frozen }),
                owner: { _, body in
                    state.sent.append(body)
                    switch body["op"] as? String {
                    case "feed.adopt":
                        // The workspace moves into an incognito window while the adopt is in flight; it commits.
                        state.normal = []
                        return [:]
                    case "feed.adopt.cancel": return ["value": ["cancelled": false]]
                    default: return [:]
                    }
                },
                isSignedIn: { true }, installID: { "inst_test" },
                policy: { FeedHandoffPolicy(preferences: .init(), mutedWorkspaces: [], normalWindows: state.normal) })
            driver?.run()
        }
        let ops = state.sent.map { $0["op"] as? String ?? "?" }
        #expect(step == "done", "the daemon must record the committed move")
        #expect(ops == ["feed.adopt", "feed.adopt.cancel", "feed.archive"],
                "an item whose workspace moved into an incognito window during the send stayed in the Feed: \(ops)")
        let archived = (state.sent.last?["params"] as? [String: Any])?["items"] as? [String]
        #expect(archived == [FeedHandoffDriver.cloudID(install: "inst_test", local: frozen.id)])
        _ = driver
    }

    @Test func aNormalWorkspacesItemStillHandsOff() throws {
        let policy = try policy()
        let content = policy.content(for: Self.item(workspace: "ws_normal", terminal: "term_normal"))
        #expect(content?.title == "Claude finished")
        #expect(content?.body == "Rotated the production signing key.")
    }
}
