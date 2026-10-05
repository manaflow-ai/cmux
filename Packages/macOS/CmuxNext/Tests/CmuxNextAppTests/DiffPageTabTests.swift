import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// diff-host S4: the diff viewer is a pane tab (an internal page), the focused
/// diff tab sets `diffViewerFocused` for its navigation actions, and the user
/// language pack is read and watched the way the page dev host reads it.
@MainActor
@Suite(.serialized)
struct DiffPageTabTests {
    /// `diffViewerFocused` has one rule, the trunk's: the focused page's id is `cmux.diff`.
    @Test func aFocusedDiffTabSetsDiffViewerFocused() {
        let diff = KeyOwnershipMatrixTests.focused(.page, tab: "local-page:diff:1")
        #expect(diff.context == FocusState.Context())
        #expect(KeyRouter.keyContext(for: diff, appContext: [], facts: .init(pageID: PageDescriptor.diff.id)).bits.contains(.diffViewerFocused))
        #expect(!KeyRouter.keyContext(for: diff, appContext: [], facts: .init()).bits.contains(.diffViewerFocused))
        #expect(KeyRouter.surfaceKind(diff.resolved) == "diff")
        let settings = KeyOwnershipMatrixTests.focused(.page, tab: "local-page:settings:1")
        #expect(settings.context == FocusState.Context())
        // A bit another window published never leaks into this window's keys.
        let terminal = KeyOwnershipMatrixTests.focused(.terminal, tab: "t1")
        #expect(!KeyRouter.keyContext(for: terminal, appContext: [.diffViewerFocused], facts: .init()).bits.contains(.diffViewerFocused))
    }

    /// The bare-key rule (60ea7ec8a8d): j, k and / reach the binding table only in a page that owns
    /// them; the diff page owns diffViewerFocused, and with the app's own bindings its actions run
    /// (they are bound for the diff page, not left unavailable). With no diff page they do not.
    @Test func aBareKeyOnAFocusedDiffPageRunsItsAction() {
        let services = ActionBindingCoverageTests.boundServices()
        let router = services.keyRouter!
        let diffPage = PageKeyOwnershipTests.context(page: PageDescriptor.diff.id)
        for (chars, code, action) in [("j", UInt16(38), "diffViewerNextLine"), ("k", UInt16(40), "diffViewerPreviousLine"),
                                      ("/", UInt16(44), "diffViewerSearch")] {
            let key = PageKeyOwnershipTests.key(chars, code: code)
            #expect(router.bareKeyWinner(key, context: diffPage)?.command.rawValue == action, "\(chars)")
            #expect(services.registry.unavailableReason(for: ActionID(rawValue: action)) == nil, "\(action) is bound for the diff page")
            #expect(router.bareKeyWinner(key, context: PageKeyOwnershipTests.context(page: nil)) == nil, "\(chars) with no diff page")
        }
    }

    @Test func navigationRefusesWithoutAFocusedDiffTab() {
        let services = ActionBindingCoverageTests.boundServices()
        services.registry.context = [.diffViewerFocused]
        #expect(ActionBindingCoverageTests.run(services, "diffViewerNextHunk") == .refused(DiffPageStrings.noDiffTab))
    }

    @Test func everyNavigationActionSendsAPageCommandTheDiffPageTakes() {
        let registry = ActionBindingCoverageTests.boundServices().registry
        #expect(DiffPageCommand.forAction.count == 11)
        for (action, command) in DiffPageCommand.forAction {
            #expect(registry.isBound(ActionID(rawValue: action)), "\(action)")
            #expect(PageDescriptor.diff.commands.contains(command), "\(action) -> \(command)")
        }
    }

    /// A main window with one pane, and a diff service whose session host
    /// knows one repository, `/tmp/project` (and its subfolder).
    private func world() async throws -> (AppServices, DiffPageService, PaneController) {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content?.panes.isEmpty == false }
        let pane = try #require(window.content?.panes.values.first)
        let runtime = DiffPageRuntime(root: try DiffPageProviderTests.root(), sidecar: .some(nil), status: { folder in
            guard folder.hasPrefix("/tmp/project") else { throw DiffOpenFailure.notRepository }
            return ["root": "/tmp/project", "branch": "feature", "base": "origin/main"]
        })
        let recents = DiffRecents(url: FileManager.default.temporaryDirectory.appending(path: "cmux-diff-recents-\(UUID().uuidString).json"))
        let service = DiffPageService(services: services, runtime: runtime, recents: recents)
        services.pages.register(service)
        return (services, service, pane)
    }

    /// The one entry point (R89's picker calls it too): a folder opens the
    /// tab of its repository; the same repository and source again selects it.
    @Test func openingAFolderOpensOneTabForItsRepository() async throws {
        let (services, service, pane) = try await world()
        let key = try await service.open(folder: URL(fileURLWithPath: "/tmp/project/sub"), in: pane, focus: true)
        #expect(LocalPageTab.page(of: key) == .diff)
        #expect(services.pages.tabIDs(in: pane.paneKey) == [key])
        #expect(services.pages.stripItem(key).title == "project")
        #expect(pane.stripModel.selectedID?.rawValue == key)
        #expect(try await service.open(folder: URL(fileURLWithPath: "/tmp/project"), in: pane, focus: true) == key)
        let staged = try await service.open(folder: URL(fileURLWithPath: "/tmp/project"), source: .staged, in: pane, focus: false)
        #expect(services.pages.tabIDs(in: pane.paneKey) == [key, staged])
        #expect(pane.stripModel.selectedID?.rawValue == key)
        #expect(services.closeLocalTab(key))
        #expect(services.pages.tabIDs(in: pane.paneKey) == [staged])
        #expect(!service.openKeys.contains(key))
    }

    /// Every repository open is recorded as a recent.
    @Test func repositoryOpensAreRecorded() async throws {
        let (_, service, pane) = try await world()
        _ = try await service.open(folder: URL(fileURLWithPath: "/tmp/project"), in: pane, focus: false)
        // The record is one queued hop after the open.
        var newest: String?
        for _ in 0..<200 where newest == nil {
            await Task.yield()
            newest = await service.recents.list().first?.path
        }
        #expect(newest == "/tmp/project")
    }

    /// R89 wins (React UIs lead P2-2): the viewer seam rethrows a folder in no repository, so the
    /// open actions show the picker; no empty diff tab opens.
    @Test func theViewerSeamRethrowsAFolderInNoRepository() async throws {
        let (services, service, pane) = try await world()
        await #expect(throws: ActionFailure.self) {
            try await service.openDiff(directory: "/tmp/elsewhere", in: pane, focus: true)
        }
        #expect(services.pages.tabIDs(in: pane.paneKey).isEmpty)
    }

    @Test func aFolderInNoRepositoryOpensNothing() async throws {
        let (services, service, pane) = try await world()
        await #expect(throws: DiffOpenFailure.notRepository) {
            try await service.open(folder: URL(fileURLWithPath: "/tmp/elsewhere"), in: pane, focus: true)
        }
        #expect(services.pages.tabIDs(in: pane.paneKey).isEmpty)
    }

    @Test func theOpenSourceSetsTheFirstSession() {
        let repository = DiffRepository(root: "/r", branch: "f", base: "origin/main")
        let source = { (source: DiffOpenSource) in DiffPageConfig.make(repository: repository, source: source, token: "t")["payload"]?["sessionSource"] }
        #expect(source(.default) == ["kind": "branch", "repoRoot": "/r", "baseRef": "origin/main"])
        #expect(source(.branch(base: "main")) == ["kind": "branch", "repoRoot": "/r", "baseRef": "main"])
        #expect(source(.staged) == ["kind": "staged", "repoRoot": "/r"])
        #expect(source(.unstaged) == ["kind": "unstaged", "repoRoot": "/r"])
    }

    @Test func theLanguagePackReadsJSONFilesOneFolderDeep() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-diff-languages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "sub/deeper"), withIntermediateDirectories: true)
        for (path, text) in [("b.json", "{\"b\":1}"), ("a.json", "{\"a\":1}"), (".hidden.json", "{}"), ("notes.txt", "x"),
                             ("sub/c.json", "{\"c\":1}"), ("sub/deeper/d.json", "{}")] {
            try Data(text.utf8).write(to: directory.appending(path: path))
        }
        let pack = DiffLanguagePack.read(directory)
        let paths = pack["files"]?.arrayValue?.compactMap { $0["path"]?.stringValue }
        #expect(paths == ["a.json", "b.json", "sub/c.json"])
        #expect(pack["files"]?.arrayValue?.first?["text"]?.stringValue == "{\"a\":1}")
        #expect(DiffLanguagePack.read(directory.appending(path: "missing")) == ["files": .array([])])
        #expect(DiffLanguagePack.directory(configFile: URL(fileURLWithPath: "/u/.config/cmux/cmux-next.json")).path
            == "/u/.config/cmux/diff/languages")
    }

    @Test func aLanguageFileChangePushesTheNewPack() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-diff-languages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "lang.json")
        try Data("{\"v\":1}".utf8).write(to: file)
        let feed = DiffLanguageFeed(directory: directory)
        #expect(await feed.pack()["files"]?.arrayValue?.count == 1)
        var pushed: [JSONValue] = []
        let stop = feed.listen { pushed.append($0) }
        // The watch is armed by the first read after `listen`; a write before
        // it is armed is seen by that read, so write until a push arrives.
        #expect(await DiffSidecarProcessTests.becomesTrue { feed.watcherCount > 0 })
        var revision = 1
        let arrived = await DiffSidecarProcessTests.becomesTrue {
            if pushed.last?["files"]?.arrayValue?.count == 2 { return true }
            revision += 1
            try? Data("{\"v\":\(revision)}".utf8).write(to: directory.appending(path: "second.json"))
            return false
        }
        #expect(arrived)
        stop()
        #expect(feed.listenerCount == 0)
    }
}
