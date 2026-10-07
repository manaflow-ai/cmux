import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// R94: the icon picker opens in the one prewarmed page host. After a picker
/// was used, the app keeps a loaded page host parked in the main window, and
/// the next open shows that host: no new page view, no new WebContent process,
/// no page load on the open path. Windows are never put on screen.
@MainActor @Suite(.serialized) struct IconPickerPrewarmTests {
    static let key = WorkspaceKey(rawValue: "7a2c9e41-0b5d-4f83-9c16-2e8d4b7f1a03")

    /// The real webviews-app build (it holds the page shell), from this file's place in the repo.
    static var webviewsApp: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../Resources/markdown-viewer/webviews-app", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// A loaded page view parked in `window` with the picker already mounted, that no picker
    /// shows (the warm host).
    static func parkedHost(in window: NSWindow?, services: AppServices) -> PageWebView? {
        PageRegistry.pages(id: "cmux.icon-picker").first { page in
            page.loaded && page.window === window && page !== services.iconPicker.open?.page
        }
    }

    static func openPicker(_ services: AppServices) async throws -> IconPickerService.OpenPicker {
        _ = ActionBindingCoverageTests.run(services, "workspace.setIcon",
                                           target: ActionTargetRef(kind: .workspace, id: Self.key.rawValue))
        // The first open loads the symbol names off the main actor.
        for _ in 0..<500 where services.iconPicker.open == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(services.iconPicker.open)
    }

    @Test func theSecondPickerOpensInThePrewarmedHostWithNoNewPageView() async throws {
        PageID.registerBundledRoot(Self.webviewsApp, for: "cmux.shell")
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: Self.key, name: "w1"),
        ]))
        let controller = services.windows.openWindow(workspaces: [Self.key.rawValue])
        services.windows.reconcileMembership()
        defer { controller?.window?.close() }
        let window = try #require(controller?.window)

        // A first open (cold) and a cancel: the picker is now likely, so a host is warmed.
        _ = try await Self.openPicker(services)
        services.iconPicker.open?.provider.finish(.cancel)
        #expect(services.iconPicker.open == nil)

        // The warm host is built after a quiet period, one step per run-loop turn.
        var warm: PageWebView?
        for _ in 0..<600 {
            warm = Self.parkedHost(in: window, services: services)
            if warm != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let parked = try #require(warm, "no loaded page host was parked in the main window after a picker was used")

        // The second open takes the parked host in the same main-actor turn: already loaded.
        let pagesBefore = Set(PageRegistry.pages().map(ObjectIdentifier.init))
        let second = try await Self.openPicker(services)
        #expect(second.page === parked)
        #expect(pagesBefore.contains(ObjectIdentifier(second.page)))
        #expect(second.page.loaded)
        #expect(second.page.pageID == "cmux.icon-picker")
        services.iconPicker.open?.provider.finish(.cancel)
    }
}
