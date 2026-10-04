import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// diff-host S6, S7: the file watcher, file routing (markdown page for .md, editor page for text,
/// the browser tab's preview for images and PDFs), the pane tabs, and the focus contexts the
/// page commands need.
@MainActor
@Suite(.serialized)
struct FilePageTabTests {
    /// A disk change reaches the page once per burst, after the debounce on the injected clock.
    /// The test drives the events itself (`noteEvent`, as the kernel watcher does) and awaits the
    /// watch (`settled`), so no wall time and no kernel event timing take part; the file reads
    /// are real.
    @Test func aBurstOfDiskChangesPushesOneChangeAfterTheDebounce() async throws {
        let folder = try FileDocumentTests.folder()
        let file = folder.appending(path: "a.txt")
        try Data("v1".utf8).write(to: file)
        let clock = ManualClock()
        var pushed: [FileSnapshot?] = []
        let watch = FileChangeWatch(url: file, inWorkspace: { true }, clock: clock, debounce: .milliseconds(150)) { pushed.append($0) }
        watch.knownHash = FileDocument.hash(Data("v1".utf8))
        func fire() async {
            await clock.sleepers(atLeast: 1)
            #expect(watch.pendingCount == 1)
            clock.advance(by: .milliseconds(150))
            await watch.settled()
        }
        // An event with the file unchanged pushes nothing.
        watch.noteEvent()
        await fire()
        #expect(pushed.isEmpty)
        // A burst: the second event restarts the debounce; nothing is read before it passes.
        try Data("v2".utf8).write(to: file)
        watch.noteEvent()
        await clock.sleepers(atLeast: 1)
        try Data("v3".utf8).write(to: file)
        // Cancelling the first debounce removes its sleeper at once (ManualClock's cancel handler).
        watch.noteEvent()
        await clock.sleepers(atLeast: 1)
        clock.advance(by: .milliseconds(149))
        #expect(pushed.isEmpty)
        clock.advance(by: .milliseconds(1))
        await watch.settled()
        #expect(pushed.count == 1)
        #expect(pushed.last??.text == "v3")
        // An event that changes nothing on disk (the read's own access time) pushes nothing.
        watch.noteEvent()
        await fire()
        #expect(pushed.count == 1)
        // Deleted: one push with no snapshot.
        try FileManager.default.removeItem(at: file)
        watch.noteEvent()
        await fire()
        #expect(pushed.count == 2)
        #expect(pushed.last.map { $0 == nil } == true, "deleted")
        watch.stop()
    }

    @Test func markdownFilesOpenTheMarkdownPageTextTheEditorAndImagesThePreview() {
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/README.md")) == .markdown)
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/notes.MARKDOWN")) == .markdown)
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/src/main.ts")) == .editor)
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/Makefile")) == .editor)
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/index.html")) == .editor, "shown as text, never run")
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/logo.png")) == nil)
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/r/paper.pdf")) == nil)
    }

    private func world() async throws -> (AppServices, PaneController) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content?.panes.isEmpty == false }
        return (services, try #require(window.content?.panes.values.first))
    }

    /// A file opens as a pane tab named after it; opening it again selects that tab.
    @Test func aFileOpensOneTabPerFileNamedAfterIt() async throws {
        let (services, pane) = try await world()
        let folder = try FileDocumentTests.folder()
        let file = folder.appending(path: "main.ts")
        try Data("let a = 1\n".utf8).write(to: file)
        let key = services.editorPages.open(file, in: pane, focus: true)
        #expect(LocalPageTab.page(of: key) == .editor)
        #expect(services.pages.stripItem(key).title == "main.ts")
        #expect(pane.stripModel.selectedID?.rawValue == key)
        #expect(services.editorPages.open(file, in: pane, focus: true) == key)
        let empty = services.markdownPages.openEmpty(in: pane, focus: false)
        #expect(LocalPageTab.page(of: empty) == .markdown)
        #expect(services.pages.tabIDs(in: pane.paneKey) == [key, empty])
        #expect(services.closeLocalTab(key))
        #expect(!services.editorPages.openKeys.contains(key))
    }

    /// The file viewer seam (R89) now opens the file pages, so Open File..., the picker, the CLI
    /// and followed links all reach them.
    @Test func theFileSeamRoutesToTheFilePages() async throws {
        let (services, pane) = try await world()
        #expect(services.viewers.fileOpener is FilePageOpener)
        let folder = try FileDocumentTests.folder()
        let markdown = folder.appending(path: "notes.md")
        let code = folder.appending(path: "app.swift")
        try Data("# n\n".utf8).write(to: markdown)
        try Data("print(1)\n".utf8).write(to: code)
        #expect(services.viewers.fileOpener.open(markdown, in: pane) == nil)
        #expect(services.viewers.fileOpener.open(code, in: pane) == nil)
        let pages = services.pages.tabIDs(in: pane.paneKey).compactMap(LocalPageTab.page(of:))
        #expect(pages == [.markdown, .editor])
        #expect(services.viewers.fileOpener.open(folder.appending(path: "gone.ts"), in: pane)?.isEmpty == false)
        // file.open with a path goes the same way.
        var invocation = ActionInvocation(arguments: ["path": .string(code.path)])
        invocation.target = ActionTargetRef(kind: .pane, id: pane.paneKey)
        #expect(services.registry.perform("file.open", invocation: invocation))
        #expect(services.pages.tabIDs(in: pane.paneKey).count == 2, "the open file's tab is selected, not duplicated")
    }

    @Test func focusedFilePagesSetTheirKeyContexts() {
        let markdown = KeyOwnershipMatrixTests.focused(.page, tab: "local-page:markdown:1")
        // markdownFocused comes from the focused page's id (the trunk's rule), not the tab kind.
        #expect(markdown.context == FocusState.Context())
        #expect(KeyRouter.keyContext(for: markdown, appContext: [], facts: .init(pageID: PageDescriptor.markdown.id))
            .bits.contains(.markdownFocused))
        #expect(!KeyRouter.keyContext(for: markdown, appContext: [], facts: .init()).bits.contains(.markdownFocused))
        let editor = KeyOwnershipMatrixTests.focused(.page, tab: "local-page:editor:1")
        #expect(editor.context == FocusState.Context(filePreview: true))
        #expect(KeyRouter.keyContext(for: editor, appContext: [], facts: .init()).bits.contains(.filePreviewFocused))
        #expect(KeyRouter.surfaceKind(editor.resolved) == "editor")
        let terminal = KeyOwnershipMatrixTests.focused(.terminal, tab: "t1")
        #expect(!KeyRouter.keyContext(for: terminal, appContext: [.filePreviewFocused, .markdownFocused], facts: .init())
            .bits.contains(.filePreviewFocused))
        #expect(ActionContext.focusBits.isSuperset(of: [.markdownFocused, .filePreviewFocused]))
    }

    /// Every page command comes from the one key dispatcher: each action is bound, needs its
    /// page's context, and sends a command the page takes.
    @Test func everyFilePageActionSendsACommandItsPageTakes() throws {
        let registry = ActionBindingCoverageTests.boundServices().registry
        for (action, command) in MarkdownPageCommand.forAction {
            #expect(registry.isBound(ActionID(rawValue: action)), "\(action)")
            #expect(PageDescriptor.markdown.commands.contains(command), "\(action) -> \(command)")
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == action }, "\(action)")
            #expect(descriptor.requires.contains(.markdownFocused), "\(action)")
        }
        for (action, command) in EditorPageCommand.forAction {
            #expect(registry.isBound(ActionID(rawValue: action)), "\(action)")
            #expect(PageDescriptor.editor.commands.contains(command), "\(action) -> \(command)")
        }
        let shortcut = { (id: ActionID) in ActionCatalog.all.first { $0.id == id }?.defaultShortcut }
        #expect(shortcut("markdownSave") == Shortcut("s", modifiers: [.command]))
        #expect(shortcut("markdownBack") == Shortcut("[", modifiers: [.command]))
        #expect(shortcut("markdownForward") == Shortcut("]", modifiers: [.command]))
        #expect(shortcut("markdownLink") == Shortcut("k", modifiers: [.command]))
    }

    @Test func filePageActionsRefuseWithoutTheirTab() {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = [.markdownFocused, .filePreviewFocused]
        #expect(ActionBindingCoverageTests.run(services, "markdownSave") == .refused(FilePageStrings.noFilePage))
        #expect(ActionBindingCoverageTests.run(services, "fileEditorGotoLine") == .refused(FilePageStrings.noFilePage))
    }
}
