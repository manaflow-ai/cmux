import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// The picker's save mode, type filters and ranking (R89): the name field
/// with path navigation, the overwrite confirmation, Save As, All Files,
/// prefix-first ranking and `name/` jumps.
@MainActor @Suite struct PickerSaveAndFilterTests {
    typealias Answer = PickerNavigationTests.Answer
    let root: URL

    init() throws {
        root = try FolderListingTests.folder(["docs/old.md", "notes.md", "a.png", "b.txt", "cla-audit/", "cloud-c10/", "cloud-c9/",
                                              "cloud-c3b/", "c2/"])
    }

    func run(_ page: (PickerSession) -> PalettePageSpec) async -> (PaletteModel, Answer) {
        let answer = Answer()
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        let session = PickerSession(environment: PickerEnvironment(home: root)) { answer.urls = .some($0) }
        model.reset(to: page(session))
        await PickerNavigationTests.settle(model)
        return (model, answer)
    }

    var markdownOrText: PickerFilter {
        PickerFilter(types: [PickerFilter.FileType(name: "Markdown", extensions: ["md"]),
                             PickerFilter.FileType(name: "Plain Text", extensions: ["txt"])])
    }

    func save(_ name: String) async -> (PaletteModel, Answer) {
        await run { $0.page(for: FolderPickerState(mode: PickerMode(kind: .save, filter: markdownOrText), start: root), query: name) }
    }

    @Test func theNameIsPrefilledWithItsNamePartSelected() async {
        let (model, _) = await save("draft.md")
        #expect(model.query == "draft.md")
        #expect(model.selectsQuery)
        #expect(model.selectedQueryLength == 5)
        #expect(model.rows.first?.id == "picker.save")
        #expect(model.rows.contains { $0.id == "dir:" + root.appendingPathComponent("docs").standardizedFileURL.path })
        #expect(!model.rows.contains { $0.id.hasPrefix("file:") }, "save lists folders to go to, not files")
    }

    @Test func typingTheNameKeepsTheFoldersListedAndReturnSaves() async {
        let (model, answer) = await save("")
        model.query = "plan"
        await model.settle()
        #expect(model.rows.first?.item.title.contains("plan.md") == true)
        #expect(model.rows.contains { $0.id.hasPrefix("dir:") })
        #expect(model.rows.contains { $0.id == "picker.saveAs.1" })
        model.handle(.submit)
        #expect(answer.urls == .some([root.appendingPathComponent("plan.md")]))
    }

    @Test func aTypedFolderPathNavigatesAndKeepsTheName() async {
        let (model, answer) = await save("")
        model.query = "docs/"
        await PickerNavigationTests.settle(model)
        #expect(model.pageTitle.hasSuffix("docs"))
        #expect(model.query.isEmpty)
        model.query = "next"
        await model.settle()
        model.handle(.submit)
        #expect(answer.urls == .some([root.appendingPathComponent("docs/next.md")]))
    }

    @Test func anExistingNameAsksBeforeReplacingAndCancelKeepsTheName() async {
        let (model, answer) = await save("notes.md")
        model.handle(.submit)
        await PickerNavigationTests.settle(model)
        #expect(model.rows.map(\.id) == ["confirm.question", "confirm.cancel", "confirm.replace"])
        #expect(model.selectedRowID == "confirm.cancel", "Return as it opens keeps the file")
        #expect(answer.urls == .none)
        model.handle(.submit)
        await PickerNavigationTests.settle(model)
        #expect(model.query == "notes.md")
        #expect(model.rows.first?.id == "picker.save")
        model.handle(.submit)
        await PickerNavigationTests.settle(model)
        model.send(.select("confirm.replace"))
        model.handle(.submit)
        #expect(answer.urls == .some([root.appendingPathComponent("notes.md")]))
    }

    @Test func saveAsSwitchesTheType() async {
        let (model, answer) = await save("draft")
        model.send(.select("picker.saveAs.1"))
        model.handle(.submit)
        await PickerNavigationTests.settle(model)
        #expect(model.query == "draft.txt")
        model.handle(.submit)
        #expect(answer.urls == .some([root.appendingPathComponent("draft.txt")]))
    }

    @Test func typeFiltersListOnlyTheirFilesUntilAllFiles() async throws {
        let images = PickerFilter(types: [PickerFilter.FileType(.image)])
        let (model, _) = await run { $0.page(for: FolderPickerState(mode: PickerMode(kind: .open(.files), filter: images), start: root)) }
        let files = { model.rows.filter { $0.id.hasPrefix("file:") }.map(\.item.title) }
        #expect(files() == ["a.png"])
        model.send(.select("picker.allFiles"))
        model.handle(.submit)
        await PickerNavigationTests.settle(model)
        #expect(files() == ["a.png", "b.txt", "notes.md"])
        #expect(model.rows.contains { $0.id == "picker.allFiles" }, "the row now switches back")
    }

    /// The reference's fuzzy order put `cla-audit` between `cloud-c9` and
    /// `cloud-c3b` for `c`: prefix matches rank first, in Finder order.
    @Test func prefixMatchesRankFirstInFinderOrder() async {
        let (model, _) = await run { $0.page(for: FolderPickerState(mode: .folder, start: root)) }
        model.query = "c"
        await model.settle()
        let names = model.rows.filter { $0.id.hasPrefix("dir:") }.map(\.item.title)
        #expect(names == ["c2", "cla-audit", "cloud-c3b", "cloud-c9", "cloud-c10", "docs"])
    }

    /// Path mode: `~/` is home only as a path; Tab completes the selected
    /// segment, Return goes there.
    @Test func aTypedPathCompletesWithTabAndReturnGoesThere() async {
        let (model, _) = await run { $0.page(for: FolderPickerState(mode: .file(.any), start: root.appendingPathComponent("docs"))) }
        model.query = "~/clo"
        await PickerNavigationTests.settle(model)
        #expect(model.currentPageID == "picker.path")
        #expect(model.rows.map(\.item.title) == ["cloud-c3b/", "cloud-c9/", "cloud-c10/"])
        #expect(model.handle(.openActions))
        await PickerNavigationTests.settle(model)
        #expect(model.query == "~/cloud-c3b/")
        #expect(model.rows.first?.id == "path.go")
        model.query = "~/do"
        await PickerNavigationTests.settle(model)
        model.handle(.submit)
        await PickerNavigationTests.settle(model)
        #expect(model.currentPageID == "picker")
        #expect(model.query.isEmpty)
        #expect(model.pageTitle.hasSuffix("docs"))
    }

    @Test func leavingPathModeFiltersTheFolderAgain() async {
        let (model, _) = await run { $0.page(for: FolderPickerState(mode: .folder, start: root)) }
        model.query = "/"
        await PickerNavigationTests.settle(model)
        #expect(model.currentPageID == "picker.path")
        model.handle(.escape)
        await PickerNavigationTests.settle(model)
        #expect(model.currentPageID == "picker")
        #expect(model.query.isEmpty)
        #expect(model.pageTitle == "~")
    }
}
