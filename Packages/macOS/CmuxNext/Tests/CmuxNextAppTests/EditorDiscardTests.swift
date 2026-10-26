import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextDiff
import CmuxNextFilesUI
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Page policies batch 3 (p07-memory-026, `memoryDiscardInternalPages`): the Files tree, the Files
/// pane, Find, the Markdown and code editor pages and the diff each declare when a hidden tab's view
/// goes, what keeps it and what it saves. A file page with unsaved edits is never discarded at any
/// pressure (Chrome's `kUserEdits`, cmux's lead rule); markdown and diff pages save their place,
/// Find its query and selected result.
@MainActor @Suite(.serialized)
struct EditorDiscardTests {
    static let batchThree: [InternalPageID] = [.files, .filesPane, .findPane, .markdown, .editor, .diff]

    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    static func documents() -> FileQuitDocuments {
        let drafts = RecoveryDraftStore(directory: FileManager.default.temporaryDirectory.appending(path: "editor-discard-\(UUID().uuidString)"))
        return FileQuitDocuments(drafts: drafts, registry: QuitUnsavedRegistry(drafts: drafts))
    }

    // MARK: Policies

    @Test func everyProviderOfTheBatchIsDiscardedTenMinutesAfterItHides() {
        let services = Self.services()
        let providers: [any InternalPageProvider] = [
            FileTreePageService(services: services),
            FilesPaneService(services: services),
            FindPaneService(services: nil),
            FilePageService(services: services, kind: .markdown, documents: Self.documents()),
            FilePageService(services: services, kind: .editor, documents: Self.documents()),
            DiffPageService(services: services),
        ]
        #expect(providers.map(\.page) == Self.batchThree)
        for provider in providers {
            #expect(provider.discardPolicy(for: "tab") == .afterHidden(.seconds(600)), "\(provider.page.rawValue)")
        }
    }

    /// Each provider of the batch says its policy in its own source, not through the protocol's default.
    @Test func everyProviderOfTheBatchDeclaresItsPolicy() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/CmuxNextApp")
        let files = ["Pages/FileTree/FileTreePageService.swift", "FilesPane/FilesPaneService.swift", "FileExplorer/FindPaneService.swift",
                     "Pages/Files/FilePageService.swift", "Pages/Diff/DiffPageService.swift"]
        for file in files {
            let source = try String(contentsOf: app.appending(path: file), encoding: .utf8)
            #expect(source.contains("func discardPolicy(for key: String) -> ContentDiscardPolicy"), "\(file)")
        }
    }

    // MARK: Unsaved edits

    @Test(arguments: FilePageKind.allCases)
    func aFileWithUnsavedEditsKeepsItsPageAtEveryPressure(kind: FilePageKind) async throws {
        let documents = Self.documents()
        let service = FilePageService(services: Self.services(), kind: kind, documents: documents)
        let key = LocalPageTab.makeKey(kind.page)
        let file = URL(fileURLWithPath: "/tmp/editor-discard-\(UUID().uuidString).md")
        service.restore(file.path, for: key)
        #expect(service.keepReasons(for: key).isEmpty, "a tab with nothing edited may go")

        let document = try #require(documents.document(for: file, holder: kind.namespace + ":" + key, writable: { true }))
        document.edited(text: "# Edited\n", baseHash: FileDocument.hash(Data("# Saved\n".utf8)))
        #expect(document.hasUnsavedChanges)
        let reasons = service.keepReasons(for: key)
        #expect(reasons == [.unsavedEdits])

        // The planner protects it from every discard cmux makes on its own, memory pressure included.
        let planner = ContentDiscardPlanner()
        let candidate = ContentDiscardPlanner.Candidate(key: key, kind: .internalPage, hiddenFor: 86_400,
                                                        hasUnsavedEdits: reasons.contains(.unsavedEdits))
        for discard in [DiscardReason.proactive, .urgent, .frozenWithGrowingMemory] {
            let eligibility = planner.eligibility(of: candidate, setting: .fallback, for: discard)
            #expect(eligibility.result == .protected, "\(discard)")
            #expect(eligibility.reason == .unsavedEdits)
        }

        document.saved(hash: FileDocument.hash(Data("# Edited\n".utf8)))
        #expect(service.keepReasons(for: key).isEmpty, "saved, the page may go again")
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
        #expect(service.route(for: key) == file.path, "the tab keeps its file")
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

    // MARK: Find

    static let match = RipgrepMatch(path: "/tmp/project/Sources/App.swift", relativePath: "Sources/App.swift",
                                    line: 12, column: 5, preview: "let needle = 1")
    static let other = RipgrepMatch(path: "/tmp/project/Sources/Other.swift", relativePath: "Sources/Other.swift",
                                    line: 3, column: 1, preview: "needle()")

    static func findView() -> FindSectionView {
        let model = FindSectionModel { _, _ in .matches([Self.other, Self.match], limited: false) }
        return FindSectionView(model: model, rootFolder: { URL(fileURLWithPath: "/tmp/project", isDirectory: true) },
                               effects: FileExplorerTests.Recorder())
    }

    @Test func aDiscardedFindTabSearchesAgainAndSelectsTheResultItHad() async throws {
        let service = FindPaneService(services: nil)
        let before = Self.findView()
        before.field.stringValue = "needle"
        await before.model.search("needle")
        for _ in 0..<100 where before.table.numberOfRows < 2 { await Task.yield() }
        before.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let state = await service.saveViewState(for: "tab", content: before)
        #expect(state.search == "needle")
        #expect(state.selection == FindSectionView.cursor(of: Self.match))

        let after = Self.findView()
        service.restoreViewState(state, for: "tab", content: after)
        #expect(after.field.stringValue == "needle")
        for _ in 0..<200 where after.cursor == nil { await Task.yield() }
        #expect(after.cursor == FindSectionView.cursor(of: Self.match))
    }

    @Test func aFindTabWithNoQueryRestoresNothing() async {
        let service = FindPaneService(services: nil)
        let view = Self.findView()
        let state = await service.saveViewState(for: "tab", content: view)
        #expect(state.search == "")
        service.restoreViewState(state, for: "tab", content: view)
        #expect(view.model.query == "")
    }
}
