import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserImport
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// #31658 (the second path of #31502): every create of a new workspace into a window goes through
/// `WorkspaceHandlers.createAndShow`, which claimed the window for its workspace only inside its
/// `Task`, after the connection check, and never released the claim when the create failed. A
/// selection repair before the claim found a window that entered an empty space for its workspace
/// (Open Link in New Space) waiting for nothing, and moved it back; a failed create left the window
/// waiting (and refusing Gather Windows) for good. Each entry point must claim in its own turn and
/// release the claim when its create fails. This app has no daemon connection, so every create fails.
@MainActor @Suite(.serialized)
struct CreateAndShowClaimsTests {
    /// Each entry point that creates through `createAndShow`, as its handler calls it. Where the
    /// handler needs what a unit test cannot make (a live page, a Cloud machine, the folder
    /// panel), the case makes the handler's own `createAndShow` call.
    enum Entry: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case linkInNewSpace, linkInNewWorkspace, linkInNewWindow, pageLinkInNewWorkspace, newBrowserWorkspace, cloudDesktop, importedTabs, openFolder
        var testDescription: String { rawValue }
    }

    private static let url = URL(string: "https://example.com/")!

    @Test(arguments: Entry.allCases)
    func theWindowClaimsItsNewWorkspaceInTheTurnAndAFailedCreateReleasesIt(_ entry: Entry) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1","frontend-browser-tabs-v1"]}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let empty = ProfileID(rawValue: "room-empty"), full = ProfileID(rawValue: "room-full")
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k1"), name: "k1", screens: []),
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
        #expect(windows.claims.pending.isEmpty)

        let context = AppActionContext(services: services)
        switch entry {
        case .linkInNewSpace:
            BrowserHitHandlers.openInNewSpace(Self.url, opener: nil, room: empty, state: state, services)
        case .linkInNewWorkspace:
            try BrowserHitHandlers.openWorkspace(Self.url, newWindow: false, window: state.id, room: nil, services)
        case .linkInNewWindow:
            try BrowserHitHandlers.open(Self.url, .newWindow, ActionInvocation(), context)
        case .pageLinkInNewWorkspace: // BrowserPageRequests.openInNewWorkspace's call
            WorkspaceHandlers.createAndShow(services: services, newWindow: false, window: state.id, room: nil) { _, _ in }
        case .newBrowserWorkspace: // the newBrowserWorkspace action and Find Work's rows
            WorkspaceHandlers.newBrowserWorkspace(services: services, url: Self.url.absoluteString)
        case .cloudDesktop: // CloudHandlers.openDesktop's calls
            WorkspaceHandlers.createAndShow(services: services, name: "Desktop", daemon: services.machines.local) { _, _ in }
        case .importedTabs:
            let source = ImportSourceRecord(browser: .chrome, profileDirectory: "Chrome", displayName: "Chrome", proposedProfileID: "default",
                                            targetProfileID: "default")
            var batch = ImportBatch(source: source, kinds: [.openTabs])
            batch.openTabs = [ImportedTab(url: Self.url, title: nil, window: 0, pinned: false)]
            ImportedTabsOpener.open(ImportSummary(batches: [batch]), services: services)
        case .openFolder: // the Open Folder panel's completion
            WorkspaceHandlers.createAndShow(context, name: "tmp", cwd: NSTemporaryDirectory())
        }

        // In the entry point's own turn: the window waits for its new workspace.
        let waiting = Array(windows.claims.pending.values)
        #expect(waiting.count == 1, "\(entry): no claim in the press's turn: \(waiting)")
        if entry == .linkInNewWindow {
            #expect(waiting.allSatisfy { $0 != state.id }, "\(entry): the new window's claim went to the old window")
        } else {
            #expect(waiting == [state.id], "\(entry): the claim is not this window's: \(waiting)")
        }
        if entry == .linkInNewSpace {
            #expect(state.profileID == empty)
            windows.repairSelections(previous: windows.membersByWindow)
            #expect(state.profileID == empty, "the window left the new space before its workspace was created")
        }

        // The create fails (no connection): the claim goes, so the window waits for nothing.
        let deadline = ContinuousClock.now + .seconds(10)
        while !windows.claims.pending.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(windows.claims.pending.isEmpty, "\(entry): a failed create left its claim")
        if entry == .linkInNewSpace {
            #expect(state.profileID == full, "a failed create left the window in the empty space")
        }
    }
}
