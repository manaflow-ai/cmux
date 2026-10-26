import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextFilesUI

/// With two windows, a Files row's right-click menu acts on the tree it was opened in, not the
/// front window's; and Open With with no app asks the person only when the person ran it.
@MainActor @Suite(.serialized)
struct FileExplorerWindowsTests {
    private struct Harness {
        let services: AppServices
        let sections: [FileExplorerSectionView]
        let roots: [URL]
        let defaults: UserDefaults
        let suite: String

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
            for panel in NSApp.windows.compactMap({ $0 as? NSOpenPanel }) { panel.cancel(nil) }
        }
    }

    /// Two windows, each with its Files tree on its own folder and `b.txt` selected.
    private static func harness() async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-file-explorer-windows-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let first = try #require(services.windows.openWindow(workspaces: ["fe-windows-a"]))
        let second = try #require(services.windows.openWindow(workspaces: ["fe-windows-b"]))
        let sections = [services.fileExplorers.makeSection(for: first), services.fileExplorers.makeSection(for: second)]
        // The sections' own first listing (the home folder) starts here; ours supersedes it.
        await Task.yield()
        var roots: [URL] = []
        for section in sections {
            let root = try FileExplorerTests.folder()
            await section.model.setRoot(root)
            section.model.selection = try #require(section.model.rows.first { $0.name == "b.txt" }).url
            roots.append(root.standardizedFileURL)
        }
        return Harness(services: services, sections: sections, roots: roots, defaults: defaults, suite: suite)
    }

    private static func run(_ id: ActionID, from section: FileExplorerSectionView, in services: AppServices) async throws {
        let menu = try #require(section.table.contextMenu?())
        let item = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == id }, "\(id) is not in the menu")
        let action = try #require(item.action)
        let work = services.registry.capturingWork { _ = NSApp.sendAction(action, to: item.target, from: item) }
        for task in work { _ = await task.value }
    }

    @Test func aRowMenuInTheBackWindowActsOnItsOwnTree() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        let active = h.services.fileExplorers.activeExplorer
        let backIndex = try #require(h.sections.firstIndex { $0.model !== active }, "no window behind the active one")
        let frontIndex = 1 - backIndex
        h.services.registry.context.remove(.fileExplorerFocused)
        try await Self.run("fileExplorerNewFolder", from: h.sections[backIndex], in: h.services)
        let name = FileExplorerStrings.untitledFolder
        let inBack = FileManager.default.fileExists(atPath: h.roots[backIndex].appendingPathComponent(name).path)
        let inFront = FileManager.default.fileExists(atPath: h.roots[frontIndex].appendingPathComponent(name).path)
        #expect(inBack, "New Folder from the back window's menu made nothing in its tree")
        #expect(!inFront, "New Folder from the back window's menu made the folder in the front window's tree")
    }

    @Test func openWithWithNoAppIsRefusedForAScriptAndShowsNothing() async throws {
        let h = try await Self.harness()
        defer { h.close() }
        var invocation = ActionInvocation(origin: .cli)
        invocation.keyContext = h.services.registry.context.union(.fileExplorerFocused)
        var failures: [ActionWorkFailure?] = []
        let work = h.services.registry.capturingWork { _ = h.services.registry.perform("fileExplorerOpenWith", invocation: invocation) }
        for task in work { failures.append(await task.value) }
        await Task.yield()
        let refused = failures.contains { $0 != nil }
        let panelShown = NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible }
        #expect(refused, "a scripted Open With with no app reported success")
        #expect(!panelShown, "a scripted Open With with no app opened the app chooser")
    }
}
