import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Foundation
import Testing
import CmuxNextFilesUI

/// The right sidebar's Files section (classic's file explorer) and its seven actions: Open
/// Selection (Return), Open Selection (Finder Style) (Cmd-Down), Open in cmux, Reveal in Finder,
/// Copy Path, Copy Relative Path and Open With. They act on the explorer's selection while its
/// list has the keyboard (`fileExplorerFocused`).
@MainActor @Suite(.serialized)
struct FileExplorerTests {
    @MainActor final class Recorder: FileExplorerEffects {
        var viewable = true
        private(set) var openedInCmux: [URL] = []
        private(set) var openedInDefaultApp: [URL] = []
        private(set) var revealed: [URL] = []
        private(set) var copied: [String] = []
        private(set) var openedWith: [(URL, String)] = []
        /// The position each cmux open asked for (nil: the top of the file).
        private(set) var openedInCmuxAt: [FileLineLocation?] = []
        func openInCmux(_ file: URL, at position: FileLineLocation?) -> Bool {
            guard viewable else { return false }
            openedInCmux.append(file)
            openedInCmuxAt.append(position)
            return true
        }
        func openAsText(_ file: URL) -> Bool { true }
        func openInDefaultApp(_ item: URL) { openedInDefaultApp.append(item) }
        func revealInFinder(_ item: URL) { revealed.append(item) }
        func copy(_ text: String) { copied.append(text) }
        func open(_ item: URL, withApp app: String) async throws { openedWith.append((item, app)) }
    }

    nonisolated static let ids: [String] = ["fileExplorerOpenSelection", "fileExplorerOpenSelectionFinderAlias", "fileExplorerOpenInCmux",
                                "fileExplorerReveal", "fileExplorerCopyPath", "fileExplorerCopyRelativePath", "fileExplorerOpenWith"]

    /// root/{Sources/{App.swift}, README.md, .hidden, b.txt}
    static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-explorer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        for path in ["Sources/App.swift", "README.md", ".hidden", "b.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    static func model(_ root: URL) async -> FileExplorerModel {
        let model = FileExplorerModel()
        await model.setRoot(root)
        return model
    }

    @Test func theTreeListsFoldersFirstWithoutHiddenItemsAndExpandsInPlace() async throws {
        let root = try Self.folder()
        let model = await Self.model(root)
        #expect(model.rows.map(\.name) == ["Sources", "b.txt", "README.md"])
        let sources = try #require(model.rows.first)
        #expect(sources.isFolder && !sources.isExpanded)
        await model.toggle(sources.url)
        #expect(model.rows.map(\.name) == ["Sources", "App.swift", "b.txt", "README.md"])
        #expect(model.rows[1].depth == 1)
        await model.toggle(sources.url)
        #expect(model.rows.map(\.name) == ["Sources", "b.txt", "README.md"])
    }

    @Test func openSelectionOpensAFileInCmuxElseInItsAppAndTogglesAFolder() async throws {
        let model = await Self.model(try Self.folder())
        let effects = Recorder()
        let commands = FileExplorerCommands(model: model, effects: effects)
        let readme = try #require(model.rows.first { $0.name == "README.md" })
        model.selection = readme.url
        try await commands.openSelection()
        #expect(effects.openedInCmux == [readme.url])
        effects.viewable = false
        try await commands.openSelection()
        #expect(effects.openedInDefaultApp == [readme.url])
        model.selection = try #require(model.rows.first).url
        try await commands.openSelection()
        #expect(model.rows.map(\.name).contains("App.swift"))
    }

    @Test func copyRelativePathIsThePathUnderTheRoot() async throws {
        let model = await Self.model(try Self.folder())
        await model.toggle(try #require(model.rows.first).url)
        let effects = Recorder()
        model.selection = try #require(model.rows.first { $0.name == "App.swift" }).url
        try FileExplorerCommands(model: model, effects: effects).copyRelativePath()
        #expect(effects.copied == ["Sources/App.swift"])
    }

    @Test func withNothingSelectedTheActionSaysSo() async throws {
        let model = await Self.model(try Self.folder())
        #expect(throws: FileExplorerError.noSelection) { try FileExplorerCommands(model: model, effects: Recorder()).copyPath() }
    }

    @Test(arguments: ids + ["switchRightSidebarToFiles", "palette.openFilesPane"])
    func theFilesActionsAreWorkingActions(id: String) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil)
    }

    @Test func theActionsRunOnTheExplorersSelectionThroughTheRegistry() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let model = await Self.model(try Self.folder())
        let effects = Recorder()
        FileExplorerHandlers.bind(into: services.registry, explorer: { _ in FileExplorerRunTarget(model: model) }, effects: effects)
        let file = try #require(model.rows.first { $0.name == "b.txt" }).url
        model.selection = file
        var invocation = ActionInvocation(origin: .cli)
        invocation.keyContext = [.fileExplorerFocused]
        for id: ActionID in ["fileExplorerCopyPath", "fileExplorerReveal", "fileExplorerOpenInCmux"] {
            let work = services.registry.capturingWork { #expect(services.registry.perform(id, invocation: invocation)) }
            for task in work { #expect(await task.value == nil) }
        }
        #expect(effects.copied == [file.path])
        #expect(effects.revealed == [file])
        #expect(effects.openedInCmux == [file])
        var withApp = invocation
        withApp.arguments["app"] = .string("com.apple.TextEdit")
        let work = services.registry.capturingWork { #expect(services.registry.perform("fileExplorerOpenWith", invocation: withApp)) }
        for task in work { #expect(await task.value == nil) }
        #expect(effects.openedWith.map(\.1) == ["com.apple.TextEdit"])
    }

    /// A row's right-click menu is the registry's (`ActionMenuContext.fileExplorerRow`), so its
    /// rows run the actions the palette, keys and CLI run, and they run while another view has
    /// the keyboard: right-clicking a row does not focus the list. Open With is the row's apps
    /// submenu (FileExplorerOpenWithTests); the empty area offers New File and New Folder.
    @Test func theRowMenuRunsTheRegistrysActionsWithoutTheListFocused() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let model = await Self.model(try Self.folder())
        let effects = Recorder()
        FileExplorerHandlers.bind(into: services.registry, explorer: { _ in FileExplorerRunTarget(model: model) }, effects: effects)
        let section = FileExplorerSectionView(model: model, rootFolder: { nil }, perform: { _ in },
                                              rowMenu: { services.fileExplorers.rowMenu(hasSelection: $0) },
                                              openWith: FileExplorerOpenWithMenu(registry: services.registry))
        let file = try #require(model.rows.first { $0.name == "b.txt" }).url
        model.selection = file
        services.registry.context.remove(.fileExplorerFocused)

        func shown(_ menu: NSMenu) -> [String] {
            menu.items.filter { !$0.isSeparatorItem }.map { item in
                ActionRegistry.menuRun(of: item)?.id.rawValue ?? (item.submenu != nil ? "▸ \(item.title)" : "inline: \(item.title)")
            }
        }
        let menu = try #require(section.table.contextMenu?())
        let expected = ["fileExplorerOpenInCmux", "▸ \(FileExplorerStrings.openWithSubmenu)", "fileExplorerReveal",
                        "fileExplorerNewFile", "fileExplorerNewFolder", "fileExplorerRename",
                        "fileExplorerCopyPath", "fileExplorerCopyRelativePath", "fileExplorerMoveToTrash"]
        #expect(shown(menu) == expected, "the row menu is not the registry's")

        let copy = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == "fileExplorerCopyPath" })
        menu.update()
        #expect(copy.isEnabled, "Copy Path is disabled while the list does not have the keyboard")
        let action = try #require(copy.action)
        let work = services.registry.capturingWork { _ = NSApp.sendAction(action, to: copy.target, from: copy) }
        for task in work { #expect(await task.value == nil) }
        #expect(effects.copied == [file.path])

        model.selection = nil
        let empty = try #require(section.table.contextMenu?())
        #expect(shown(empty) == ["fileExplorerNewFile", "fileExplorerNewFolder"], "the empty area's menu")
    }

    @Test func theExplorersListHasItsOwnKeyContext() {
        let focus = FocusState()
        #expect(KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts(fileExplorerFocused: true)).bits.contains(.fileExplorerFocused))
        #expect(!KeyRouter.keyContext(for: focus, appContext: [.fileExplorerFocused], facts: KeyFacts()).bits.contains(.fileExplorerFocused),
                "a stale app-wide fileExplorerFocused leaked into the key context")
    }
}
