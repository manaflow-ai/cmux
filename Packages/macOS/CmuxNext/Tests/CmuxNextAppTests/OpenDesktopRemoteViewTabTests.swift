@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextBrowser
import CmuxNextDaemon
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo's goal (cloud-desktop-agent): "Leo opens a production Cloud machine's desktop from cmux, watches an agent
/// drive a browser there, takes over input and hands it back." Open Desktop (`CloudHandlers.openDesktopPane`) makes a
/// browser workspace on this Mac whose one tab is the machine's remote view record. Every production probe run that
/// reached it since 11-22 found no remote view tab (`remote_view.state` empty 30 s after the open): this runs the same
/// workspace spawn against a same-tree daemon and asks the same question, with no Cloud machine.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct OpenDesktopRemoteViewTabTests {
    /// The tab keys Open Desktop's callback named.
    @MainActor final class CalledBack: Sendable { var keys: [String] = [] }

    @Test func openDesktopsWorkspaceShowsACloudRemoteViewTab() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let host = "vm_opendesktop\(UUID().uuidString.prefix(6).lowercased())"
            let record = try #require(RemoteViewTabRecord(host: host, target: .virtual, mode: .view, cloudDesktop: true, cloudRd: true))
            let address = record.url.absoluteString
            let store = services.machines.local.store
            let calledBack = CalledBack()
            WorkspaceHandlers.show(.browser(WorkspaceFirstBrowserTab(url: address, engine: .webkit, title: "Desktop"), name: "Desktop") { _, created in
                let key = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
                await MainActor.run {
                    calledBack.keys.append(key)
                    services.cache.personOpenedRemoteView(key, url: record.url, scope: nil)
                }
            }, services: services, daemon: services.machines.local)

            @MainActor func desktopTabs() -> [TabModel] {
                store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.url?.contains(host) == true }
            }
            @MainActor func report() -> String {
                let all = store.workspaces.map { ws in
                    "\(ws.title ?? "?"): " + ws.screens.flatMap(\.panes).flatMap(\.tabs).map { "\($0.id) \($0.kind) \($0.url ?? "nil")" }.joined(separator: ", ")
                }
                let live = RemoteViewPageTab.live.allObjects.map { "\($0.id.rawValue) \($0.state.url?.absoluteString ?? "nil") cloud=\($0.record?.cloudDesktop == true)" }
                return "workspaces [\(all.joined(separator: " | "))]; live [\(live.joined(separator: ", "))]; calledBack \(calledBack.keys)"
            }
            // The daemon's tab (it has a resource id), not the stand-in.
            try await PinnedPageTests.until({ desktopTabs().contains { $0.resourceID != nil } }, report: report)
            let tab = try #require(desktopTabs().first { $0.resourceID != nil })
            #expect(tab.url == address, "the daemon's tab is not on the record: \(report())")
            // What a pane showing the tab asks for (the probe's app shows it: `cmux agents workspace select`).
            _ = services.cache.browser(for: tab)
            try await PinnedPageTests.until({ services.cache.existingBrowser(tab.id) != nil }, report: report)
            let listed = await RemoteViewTabsControl.answer([:], cloudOnly: true)
            #expect("\(listed)".contains(host),
                    "remote_view.state lists no tab for the desktop: \(listed); \(report())")
        }
    }
}
