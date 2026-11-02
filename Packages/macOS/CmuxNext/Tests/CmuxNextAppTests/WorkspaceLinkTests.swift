import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-10-29: "there's no link to workspace, which is, I mean, that seems pretty important".
/// Copy Workspace Link on a workspace row writes `<scheme>://workspace/ws_…`, and opening that
/// link (`link.open`, the path the OS URL handler, Open Link… and `cmux link open` take) shows
/// that workspace in its window. Through the app against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceLinkTests {
    @Test func copyWorkspaceLinkThenOpeningItShowsThatWorkspace() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let name = "link-ws-\(UUID().uuidString.prefix(6).lowercased())"
            let id = try await connection.state.createWorkspace(name: name, ephemeral: false, terminal: true, focus: false).workspaceID
            try await PinnedPageTests.until({ Self.workspace(id, store) != nil }, within: .seconds(30), report: { "\(name) never showed" })
            let workspace = try #require(Self.workspace(id, store))
            // The window that lists the new workspace (it was made without focus, so it shows another one).
            @MainActor func owner() -> WindowController? {
                services.windows.registry.value.owner(of: workspace.id).flatMap { owner in services.windows.controllers.first { $0.state.id == owner } }
            }
            try await PinnedPageTests.until({ owner() != nil }, report: { "\(name) is in no window" })
            let window = try #require(owner())
            if window.state.workspaceID == workspace.id {
                let other = try #require(store.workspaces.first { $0.id != workspace.id && $0.key != nil })
                services.windows.reveal(workspaceID: other.id)
            }
            #expect(window.state.workspaceID != workspace.id, "the new workspace was already shown")

            // The row's Copy Workspace Link runs; its text is the build's scheme and the workspace's `ws_` id.
            let target = ActionTargetRef(kind: .workspace, id: workspace.id)
            let copyFailures = try await Self.perform("palette.copyWorkspaceLink", ActionInvocation(target: target, origin: .cli), services)
            #expect(copyFailures.isEmpty, "\(copyFailures)")
            let link = try services.link(workspace: workspace)
            #expect(link == "\(services.linkScheme)://workspace/\(id.rawValue)")

            // Opening it as the person does (the OS URL handler, a cmux:// link clicked in the app: CmuxAppLinks,
            // origin .user) shows that workspace in the window that lists it. A CLI run never moves this
            // client's view, so `cmux link open` files it without showing it.
            let openFailures = try await Self.perform("link.open", ActionInvocation(arguments: ["url": .string(link)], origin: .user), services)
            #expect(openFailures.isEmpty, "\(openFailures)")
            try await PinnedPageTests.until({ owner()?.state.workspaceID == workspace.id },
                                            report: { "the link left \(owner()?.state.workspaceID ?? "nothing") shown, not \(workspace.id)" })
        }
    }

    /// #27934: the links Chief writes in its Home chat are the plain `cmux` scheme, whatever the build,
    /// and a click goes through ``CmuxAppLinks/open(_:services:)``. A `cmux://workspace/<ws_…>` click
    /// shows that workspace; a `cmux://tab/<tab_…>` click shows its workspace with that tab selected;
    /// a `file://` path is opened by this app, never handed to the system or dropped.
    @Test func chiefsWorkspaceTabAndFileLinksOpenWhenClicked() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let name = "chief-link-ws-\(UUID().uuidString.prefix(6).lowercased())"
            let id = try await connection.state.createWorkspace(name: name, ephemeral: false, terminal: true, focus: false).workspaceID
            try await PinnedPageTests.until({ Self.workspace(id, store)?.screens.first?.panes.first?.tabs.first?.snapshot.tabResourceID != nil },
                                            within: .seconds(30), report: { "\(name) never showed with a tab" })
            let workspace = try #require(Self.workspace(id, store))
            let pane = try #require(workspace.screens.first?.panes.first)
            let tab = try #require(pane.tabs.first)
            @MainActor func owner() -> WindowController? {
                services.windows.registry.value.owner(of: workspace.id).flatMap { owner in services.windows.controllers.first { $0.state.id == owner } }
            }
            try await PinnedPageTests.until({ owner() != nil }, report: { "\(name) is in no window" })
            let window = try #require(owner())
            let other = try #require(store.workspaces.first { $0.id != workspace.id && $0.key != nil })
            @MainActor func showOther() async throws {
                services.windows.reveal(workspaceID: other.id)
                try await PinnedPageTests.until({ window.state.workspaceID == other.id }, report: { "the other workspace never showed" })
            }
            /// The link in the Chief's own scheme (`cmux://`), as Home renders it.
            func chiefs(_ link: String) throws -> URL {
                let path = try #require(link.range(of: "://")).upperBound
                return try #require(URL(string: "cmux://" + link[path...]))
            }

            try await showOther()
            #expect(CmuxAppLinks.open(try chiefs(try services.link(workspace: workspace)), services: services))
            try await PinnedPageTests.until({ window.state.workspaceID == workspace.id },
                                            report: { "the workspace link left \(window.state.workspaceID) shown" })

            try await showOther()
            let tabLink = try chiefs(try services.link(tab: tab))
            #expect(tabLink.absoluteString.hasPrefix("cmux://tab/tab_"))
            #expect(CmuxAppLinks.open(tabLink, services: services))
            try await PinnedPageTests.until({ window.state.workspaceID == workspace.id && window.state.selection.selection(in: pane.id) == tab.id },
                                            report: { "the tab link left \(window.state.workspaceID) shown, tab \(window.state.selection.selection(in: pane.id) ?? "none")" })

            // A path link is this app's to open (LinkOpener), never the system's.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("chief-link-\(UUID().uuidString.prefix(6)).md")
            try Data("# link\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(CmuxAppLinks.open(URL(fileURLWithPath: file.path), services: services))
            #expect(!CmuxAppLinks.open(try #require(URL(string: "file:relative.md")), services: services))
        }
    }

    /// A workspace link whose workspace is gone refuses with a reason, never a silent success.
    @Test func aLinkToAGoneWorkspaceRefuses() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let link = "\(services.linkScheme)://workspace/ws_\(String(repeating: "0", count: 32))"
            let failures = try await Self.perform("link.open", ActionInvocation(arguments: ["url": .string(link)], origin: .cli), services)
            #expect(failures == [RefusalStrings.linkTargetGone], "\(failures)")
        }
    }

    private static func workspace(_ id: ResourceID, _ store: DaemonStore) -> WorkspaceModel? {
        store.workspaces.first { $0.resourceID == id && $0.key != nil }
    }

    /// Runs `id` as the CLI does (capturing its refusal and work) and returns every failure.
    private static func perform(_ id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) async throws -> [String] {
        var ran = false
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { ran = services.registry.perform(id, invocation: invocation) }
        }
        var failures = refusal.map { [$0] } ?? []
        if !ran { failures.append("\(id) did not run") }
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        return failures
    }
}
