import AppKit
import CmuxNextCompat
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextDiff
import CmuxNextFilesUI
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Page policies batch 3 (`memoryDiscardInternalPages`): the Files tree, the Files
/// pane, Find, the Markdown and code editor pages and the diff each declare when a hidden tab's view
/// goes, what keeps it and what it saves. A file page with unsaved edits is never discarded at any
/// pressure (Chrome's `kUserEdits`, cmux's lead rule); a discard changes no file's grant or route;
/// the page state comes back only from the discard that saved it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct EditorDiscardTests {
    static let batchThree: [InternalPageID] = [.files, .filesPane, .findPane, .markdown, .editor, .diff]

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    static func documents() -> FileQuitDocuments {
        let drafts = RecoveryDraftStore(directory: FileManager.default.temporaryDirectory.appending(path: "editor-discard-\(UUID().uuidString)"),
                                        deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())), work: BackgroundWork(label: "test.recovery-drafts"))
        return FileQuitDocuments(drafts: drafts, registry: QuitUnsavedRegistry(drafts: drafts))
    }

    // MARK: Policies

    @Test func everyProviderOfTheBatchIsDiscardedTenMinutesAfterItHides() {
        let services = Self.services()
        let providers: [any InternalPageProvider] = [
            FileTreePageService(services: services),
            FilesPaneService(services: services),
            FindPaneService(services: nil, mainWork: MainWorkScheduler(budget: MainFrameBudget())),
            FilePageService(services: services, kind: .markdown, documents: Self.documents()),
            FilePageService(services: services, kind: .editor, documents: Self.documents()),
            DiffPageService(services: services),
        ]
        #expect(providers.map(\.page) == Self.batchThree)
        for provider in providers {
            #expect(provider.discardPolicy(for: "tab") == .afterHidden(.seconds(600)), "\(provider.page.rawValue)")
        }
    }

    // MARK: Unsaved edits

    /// The scheduler, at critical pressure and long past the policy, never commits the discard of a
    /// tab whose file has unsaved edits: the provider's keep reason holds it, through the same
    /// ``ContentDiscardHost`` calls the page tab store makes. Saved, the tab goes.
    @Test(arguments: FilePageKind.allCases)
    func aFileWithUnsavedEditsIsNeverDiscardedAtCriticalPressure(kind: FilePageKind) async throws {
        let documents = Self.documents()
        let service = FilePageService(services: Self.services(), kind: kind, documents: documents)
        let key = LocalPageTab.makeKey(kind.page)
        let file = URL(fileURLWithPath: "/tmp/editor-discard-\(UUID().uuidString).md")
        service.restore(file.path, for: key)
        let document = try #require(documents.document(for: file, holder: kind.namespace + ":" + key, writable: { true }))
        document.edited(text: "# Edited\n", baseHash: FileDocument.hash(Data("# Saved\n".utf8)))

        let clock = ManualClock()
        let scheduler = ContentDiscardScheduler(kind: .internalPage, clock: clock)
        let host = ForwardingHost(service)
        scheduler.host = host
        scheduler.contentDidHide(key)
        scheduler.update(pressure: .critical)
        clock.advance(by: .seconds(86_400))
        scheduler.replan()
        await scheduler.settled()
        #expect(host.committed.isEmpty, "a tab with unsaved edits was discarded at critical pressure")
        #expect(scheduler.exemptions[key] == .unsavedEdits)

        document.saved(hash: FileDocument.hash(Data("# Edited\n".utf8)))
        scheduler.replan()
        await scheduler.settled()
        #expect(host.committed == [key], "saved, the tab may go")
        await document.settled()
    }

    /// A discard only the person can make (Hibernate Tab) past unsaved edits keeps them: the
    /// document stays in the quit hook, and the next page gets them as a recovered draft.
    @Test func aDiscardedEditorTabKeepsItsUnsavedDocument() async throws {
        let documents = Self.documents()
        let service = FilePageService(services: Self.services(), kind: .editor, documents: documents)
        let key = LocalPageTab.makeKey(.editor)
        let file = URL(fileURLWithPath: "/tmp/editor-discard-\(UUID().uuidString).swift")
        service.restore(file.path, for: key)
        let document = try #require(documents.document(for: file, holder: FilePageKind.editor.namespace + ":" + key, writable: { true }))
        document.edited(text: "let edited = 1\n", baseHash: FileDocument.hash(Data("let saved = 0\n".utf8)))

        service.viewDiscarded(key)
        #expect(documents.existing(file) === document)
        #expect(document.hasUnsavedChanges)
        #expect(service.keepReasons(for: key) == [.unsavedEdits])
        #expect(service.unsavedText(of: file) == "let edited = 1\n", "the next page's recovered draft")
        #expect(service.route(for: key) == file.path, "the tab keeps its file")
        await document.settled()
    }

    /// Closing a discarded tab drops its unsaved edits as a close without saving does: no quit
    /// document is left with no tab to save it.
    @Test func closingADiscardedTabWithUnsavedEditsLeavesTheQuitHook() async throws {
        let documents = Self.documents()
        let service = FilePageService(services: Self.services(), kind: .markdown, documents: documents)
        let key = LocalPageTab.makeKey(.markdown)
        let file = URL(fileURLWithPath: "/tmp/editor-discard-\(UUID().uuidString).md")
        service.restore(file.path, for: key)
        let document = try #require(documents.document(for: file, holder: FilePageKind.markdown.namespace + ":" + key, writable: { true }))
        document.edited(text: "# Edited\n", baseHash: FileDocument.hash(Data("# Saved\n".utf8)))

        service.viewDiscarded(key)
        #expect(documents.existing(file) != nil)
        service.tabClosed(key)
        #expect(documents.existing(file) == nil, "a closed discarded tab left its edits in the quit hook")
        #expect(!document.hasUnsavedChanges)
        await document.settled()
    }

    @Test func aDiscardedCleanEditorTabLeavesTheQuitHook() throws {
        let documents = Self.documents()
        let service = FilePageService(services: Self.services(), kind: .editor, documents: documents)
        let key = LocalPageTab.makeKey(.editor)
        let file = URL(fileURLWithPath: "/tmp/editor-discard-\(UUID().uuidString).swift")
        service.restore(file.path, for: key)
        _ = try #require(documents.document(for: file, holder: FilePageKind.editor.namespace + ":" + key, writable: { true }))

        service.viewDiscarded(key)
        #expect(documents.existing(file) == nil)
        #expect(service.route(for: key) == file.path)
    }

    // MARK: Grants

    /// A transcript tab (granted, read only) follows a link in place to B: B is shown, not granted,
    /// and not read only. The discard keeps exactly that, and the tab's route.
    @Test func aDiscardKeepsTheGrantsOfAFileTheTabFollowedInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "md-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "A.md"), linked = folder.appending(path: "B.md")
        try Data("# A\n[B](B.md)\n".utf8).write(to: first)
        try Data("# B\n".utf8).write(to: linked)
        let a = first.resolvingSymlinksInPath(), b = linked.resolvingSymlinksInPath()

        let service = FilePageService(services: Self.services(), kind: .markdown, documents: Self.documents())
        let key = LocalPageTab.makeKey(.markdown)
        service.restore(a.path, for: key)
        service.tabs[key]?.userChose = true
        service.tabs[key]?.readOnly = true
        let provider = FilePageProvider(kind: .markdown, file: a, userChose: true, readOnly: true, host: Host(),
                                        libraries: nil, images: NoImages())
        service.tabs[key]?.provider = provider
        let page = PageCallContext(page: "cmux.markdown")
        _ = try await provider.call("cmux.markdown.resolveLinks", params: ["from": .string(a.path), "paths": ["B.md"]], context: page)
        _ = try await provider.call("cmux.markdown.open", params: ["path": .string(b.path)], context: page)
        #expect(provider.file == b)
        let route = service.route(for: key)

        service.viewDiscarded(key)
        let access = try #require(service.tabs[key]?.access)
        #expect(!access.granted.contains(b.path), "the discard granted a file the page only followed")
        #expect(!access.readOnlyDocuments.contains(b.path), "the discard made a followed file a transcript")
        #expect(access.shown.contains(a.path), "Back to the first file is still allowed")
        #expect(service.route(for: key) == route, "the discard moved the tab's route")

        // The next provider, as makeView builds it from the tab, keeps B writable and ungranted.
        let next = FilePageProvider(kind: .markdown, file: b, userChose: true, readOnly: true, access: access, host: Host(),
                                    libraries: nil, images: NoImages())
        defer { next.close() }
        #expect(next.access.granted == access.granted)
        let config = try await next.call("cmux.markdown.config", params: [:], context: page)
        #expect(config["readOnly"] == nil, "B came back read only after the discard")
    }

    // MARK: View state

    /// The page state comes only from the discard that kept it: none for a discard nobody prepared.
    @Test func thePageStateComesBackOnlyFromItsDiscard() {
        let service = FilePageService(services: Self.services(), kind: .markdown, documents: Self.documents())
        let key = LocalPageTab.makeKey(.markdown)
        service.restore("/tmp/notes.md", for: key)
        let saved: JSONValue = ["scroll": 240, "mode": "source"]
        service.willRemakeView(for: key, with: ContentViewState(page: saved))
        #expect(service.tabs[key]?.viewState == saved)
        service.willRemakeView(for: key, with: ContentViewState())
        #expect(service.tabs[key]?.viewState == nil, "an earlier, cancelled save came back")
    }

    /// The view state deadline runs on the service's clock: a page that never answers comes back
    /// with no state after one second of it, and keeps no state from the try.
    @Test func aPageThatNeverAnswersItsViewStateGoesOnAtTheDeadline() async throws {
        let rig = try InternalPageDiscardTests.WebRig()
        defer { rig.close() }
        let page = try #require(rig.makePage() as? PageWebView)
        page.router.send = { _ in } // the page never answers
        defer { page.close() }
        let clock = ManualClock()
        let service = FilePageService(services: Self.services(), kind: .editor, clock: clock, documents: Self.documents())
        let key = LocalPageTab.makeKey(.editor)
        service.tabs[key] = FilePageService.Tab(file: URL(fileURLWithPath: "/tmp/a.swift"), page: page)

        let saving = Task { await service.saveViewState(for: key, content: page) }
        try await clock.waitForSleeper()
        clock.advance(by: FilePageService.viewStateTimeout)
        let state = await saving.value
        #expect(state.page == nil)
        #expect(service.keepReasons(for: key).isEmpty)
    }

    // MARK: Diff

    @Test func aDiffPageWithADraftOrTheCommitFormSaysSo() async throws {
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil)
        let page = PageCallContext(page: "cmux.diff")
        #expect(!provider.holdsUnsavedInput)
        _ = try await provider.call("cmux.diff.input", params: ["unsaved": true], context: page)
        #expect(provider.holdsUnsavedInput)
        _ = try await provider.call("cmux.diff.input", params: ["unsaved": false], context: page)
        #expect(!provider.holdsUnsavedInput)
    }

    /// A reload (a retarget, a crash) starts a document with no draft: the input it held is gone,
    /// and the tab may be discarded again.
    @Test func aNewDiffDocumentHoldsNoInput() async throws {
        let provider = DiffPageProvider(ready: nil, sidecar: nil, languages: nil)
        let page = PageCallContext(page: "cmux.diff")
        _ = try await provider.call("cmux.diff.input", params: ["unsaved": true], context: page)
        _ = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(!provider.holdsUnsavedInput, "a reloaded page kept its tab forever")
    }

    @Test func aRestoredDiffPageGetsItsViewStateInItsFirstConfigOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/Users/dev/uploader")
        defer { grant.remove() }
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: ["payload": [:]]) }, sidecar: nil, languages: nil)
        let saved: JSONValue = ["anchor": ["itemId": "src/upload.ts", "offset": 240], "expanded": ["package-lock.json"], "options": [:]]
        provider.viewState = saved
        let page = PageCallContext(page: "cmux.diff")

        let first = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(first["payload"]?["viewState"] == saved)
        let again = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(again["payload"]?["viewState"] == nil, "a reload of the same page starts where it is")
    }

    @Test func aDiffPageThatNeverAnswersItsViewStateGoesOnAtTheDeadline() async throws {
        let rig = try InternalPageDiscardTests.WebRig()
        defer { rig.close() }
        let page = try #require(rig.makePage() as? PageWebView)
        page.router.send = { _ in } // the page never answers
        defer { page.close() }
        let clock = ManualClock()
        let service = DiffPageService(services: Self.services(), clock: clock)
        let key = LocalPageTab.makeKey(.diff)
        service.tabs[key] = DiffPageService.Tab(repository: nil, source: .default, page: page)

        let saving = Task { await service.saveViewState(for: key, content: page) }
        try await clock.waitForSleeper()
        clock.advance(by: DiffPageService.viewStateTimeout)
        #expect(await saving.value.page == nil)
    }

    // MARK: Find

    static let match = RipgrepMatch(path: "/tmp/project/Sources/App.swift", relativePath: "Sources/App.swift",
                                    line: 12, column: 5, preview: "let needle = 1")
    static let other = RipgrepMatch(path: "/tmp/project/Sources/Other.swift", relativePath: "Sources/Other.swift",
                                    line: 3, column: 1, preview: "needle()")

    /// A shown place for the find views: their results render only while their node is visible (VisibleObservation).
    static let shown = VisibilityNode(root: "test.findTab", own: .visible)

    static func findView() -> FindSectionView {
        let model = FindSectionModel { _, _ in .matches([Self.other, Self.match], limited: false) }
        let view = FindSectionView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget()),
                                   rootFolder: { URL(fileURLWithPath: "/tmp/project", isDirectory: true) },
                                   effects: FileExplorerTests.Recorder())
        try? view.visibilityNode.attach(to: shown)
        return view
    }

    @Test func aDiscardedFindTabSearchesAgainAndSelectsTheResultItHad() async throws {
        let service = FindPaneService(services: nil, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let before = Self.findView()
        before.field.stringValue = "needle"
        await before.model.search("needle")
        for _ in 0..<100 where before.table.numberOfRows < 2 { await Task.yield() }
        before.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let state = await service.saveViewState(for: "tab", content: before)
        #expect(state.search == "needle")
        #expect(state.selection == FindSectionView.cursor(of: Self.match))
        #expect(state.scroll == before.resultsScroll)

        let after = Self.findView()
        await service.restoreViewState(state, for: "tab", content: after)
        #expect(after.field.stringValue == "needle")
        for _ in 0..<200 where after.cursor == nil { await Task.yield() }
        #expect(after.cursor == FindSectionView.cursor(of: Self.match))
    }

    @Test func aFindTabWithNoQueryRestoresNothing() async {
        let service = FindPaneService(services: nil, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let view = Self.findView()
        let state = await service.saveViewState(for: "tab", content: view)
        #expect(state.search == "")
        await service.restoreViewState(state, for: "tab", content: view)
        #expect(view.model.query == "")
    }

    // MARK: Doubles

    /// The page tab store's ``ContentDiscardHost`` calls for one file page service: policy and keep
    /// reasons from the provider, a preparation that rechecks the keep reasons, and the commits. A
    /// committed tab has no view left, so no policy (as in InternalPageTabStore).
    @MainActor final class ForwardingHost: ContentDiscardHost {
        let service: FilePageService
        private(set) var committed: [String] = []

        init(_ service: FilePageService) { self.service = service }

        func discardPolicy(of key: String) -> ContentDiscardPolicy? {
            committed.contains(key) ? nil : service.discardPolicy(for: key)
        }
        func keepReasons(of key: String) -> [CannotDiscardReason] { service.keepReasons(for: key) }
        func isDrawn(_ key: String) -> Bool { false }
        func prepareDiscard(_ key: String) async -> ContentViewState? {
            service.keepReasons(for: key).isEmpty ? ContentViewState() : nil
        }
        func commitDiscard(_ key: String) { committed.append(key) }
    }

    private final class Host: FilePageHosting {
        var roots: FileWorkspaceRoots { FileWorkspaceRoots(folders: []) }
        var remoteImages: Bool { false }
        func recents() -> JSONValue { ["items": []] }
        func record(_ url: URL) {}
        func chooseFile(start: URL?) async -> URL? { nil }
        func look() -> JSONValue { .object([:]) }
        func listenLook(_ onLook: @escaping @MainActor (JSONValue) -> Void) -> () -> Void { {} }
        func setPreference(key: String, value: JSONValue, by writer: SettingWriter) async throws {}
        func opened(_ url: URL) {}
        func openExternal(_ url: URL) {}
        func openFile(_ url: URL) {}
        func openAppLink(_ url: URL) -> Bool { false }
        func isRecent(_ path: String) -> Bool { false }
        func confirmOpen(_ url: URL, userGesture: Bool) async -> Bool { false }
        func edited(_ url: URL, text: String, baseHash: String?, writable: Bool) -> RecoveryDraftAcceptance { .kept }
        func saved(_ url: URL, hash: String) {}
    }

    private final class NoImages: RemoteImageFetching {
        func fetch(_ url: URL) async -> PageResource? { nil }
    }
}
