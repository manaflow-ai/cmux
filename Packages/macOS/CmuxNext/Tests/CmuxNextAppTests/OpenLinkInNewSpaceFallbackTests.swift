import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// #31740: Open Link in New Space entered the new, empty space before it knew where the link would
/// open. A link that opens as a plain tab instead (an incognito opener, a machine that serves no
/// browser tabs) or nowhere (the opener closed) made no workspace there, so nothing claimed the
/// window: it showed the empty space until the next selection repair moved it back, and the empty
/// space stayed. The window must enter the space only for the workspace the link makes there.
@MainActor @Suite(.serialized)
struct OpenLinkInNewSpaceFallbackTests {
    enum Outcome: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// No opener, browser tabs served: a new workspace holds the link (the space is entered).
        case workspace
        /// No opener, and this machine serves no browser tabs: no workspace.
        case noBrowserTabs
        /// The opener page closed before the space was mirrored: nothing opens.
        case openerGone
        /// An incognito opener: a tab beside it, never a workspace in a normal space.
        case incognitoOpener
        /// An opener whose machine serves no browser tabs: a tab beside it.
        case openerWithoutBrowserTabs
        var testDescription: String { rawValue }
        var servesBrowserTabs: Bool { self != .noBrowserTabs && self != .openerWithoutBrowserTabs }
    }

    @Test(arguments: Outcome.allCases)
    func theWindowEntersTheNewSpaceOnlyForTheWorkspaceItsLinkMakes(_ outcome: Outcome) throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let capabilities = ["profiles-v1", "personal-mixed-order-v1"] + (outcome.servesBrowserTabs ? ["frontend-browser-tabs-v1"] : [])
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":"# + "\(capabilities)" + "}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let empty = ProfileID(rawValue: "room-empty"), full = ProfileID(rawValue: "room-full")
        let page = TabSnapshot(surface: 1, kind: .browser, title: "opener", url: "https://example.com/")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [page])])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1", screens: [screen]),
        ])
        tree.personal = PersonalState(
            sessions: [SessionRecord(id: "s-local")],
            profiles: [ProfileSnapshot(id: full, name: "Full", index: 0), ProfileSnapshot(id: empty, name: "Empty", index: 1)],
            pins: [WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), profile: full)],
            workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 0)])
        store.apply(snapshot: tree)

        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let state = controller.state, windows = services.windows
        #expect(state.profileID == full)

        // The opener: a page this app shows for the workspace's browser tab, or one it no longer has.
        var opener: (any BrowserTab)?
        if outcome == .openerGone || outcome == .incognitoOpener || outcome == .openerWithoutBrowserTabs {
            let mock = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
            if outcome != .openerGone {
                let key = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first?.id, "the opener's tab")
                _ = services.cache.install(mock, for: key)
                if outcome == .incognitoOpener { services.cache.browserTabs.isIncognitoTab = { $0 == key } }
                #expect(services.cache.key(of: mock) == key)
            }
            opener = mock
        }

        let link = try #require(URL(string: "https://example.com/next"))
        BrowserHitHandlers.openInNewSpace(link, opener: opener, room: empty, state: state, services)
        // In the turn the space is mirrored, and after a selection repair.
        for moment in ["in the turn", "after a repair"] {
            if moment == "after a repair" { windows.repairSelections(previous: windows.membersByWindow) }
            if outcome == .workspace {
                #expect(state.profileID == empty, "\(moment): the window is not in the space its link's workspace is made in")
                #expect(windows.claims.pending.values.contains(state.id), "\(moment): no claim for the link's workspace")
            } else {
                #expect(state.profileID == full, "\(outcome) \(moment): the window entered a space its link makes no workspace in")
                #expect(!windows.claims.pending.values.contains(state.id), "\(outcome) \(moment): a claim with no workspace")
            }
        }
    }
}
