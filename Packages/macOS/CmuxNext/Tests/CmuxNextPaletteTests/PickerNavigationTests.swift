import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

/// The cmux picker driven through the palette model and its key map, on a
/// temporary folder (R89): enter, up, filter, choose, the list keys,
/// hidden files, jumps, and the drill keys only on a tree page.
@MainActor @Suite struct PickerNavigationTests {
    final class Answer {
        var urls: [URL]?? = .none
    }

    final class Memory: PickerExplainerMemory {
        var hasShownExplainer = false
    }

    let root: URL

    init() throws {
        root = try FolderListingTests.folder(["api/.git/", "api/src/", "web/", "docs/guide.md", "README.md", "main.swift", ".config/"])
    }

    func open(_ mode: PickerMode, at start: URL? = nil, home: URL? = nil, memory: Memory? = nil,
              recents: [String] = [], locations: [PickerLocation] = []) async -> (PaletteModel, Answer, PickerSession) {
        let answer = Answer()
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        let environment = PickerEnvironment(home: home ?? root, recents: recents, locations: locations, explainer: memory)
        let session = PickerSession(environment: environment) { answer.urls = .some($0) }
        model.reset(to: session.page(for: FolderPickerState(mode: mode, start: start ?? root)))
        await Self.settle(model)
        return (model, answer, session)
    }

    /// Waits for the page's listing (read off the main actor) and search.
    static func settle(_ model: PaletteModel) async {
        for _ in 0..<400 {
            await model.settle()
            if !model.isLoading, !model.rows.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func ids(_ model: PaletteModel) -> [String] { model.rows.map(\.id) }
    func path(_ name: String) -> String { root.appendingPathComponent(name).standardizedFileURL.path }

    @Test func listsOneLevelFoldersFirstWithGitMarked() async {
        let (model, _, _) = await open(.file(.any))
        #expect(ids(model) == ["dir:" + path("api"), "dir:" + path("docs"), "dir:" + path("web"),
                               "file:" + path("main.swift"), "file:" + path("README.md")])
        #expect(model.rows.first?.item.symbol == "arrow.triangle.branch")
        #expect(model.pageTitle.hasSuffix("~"))
    }

    @Test func tabEntersAndBackspaceGoesUpSelectingTheFolderLeft() async {
        let (model, _, _) = await open(.file(.any))
        model.send(.select("dir:" + path("api")))
        #expect(model.handle(.openActions))
        await Self.settle(model)
        #expect(ids(model) == ["dir:" + path("api/src")])
        #expect(model.pageTitle.hasSuffix("api"))
        #expect(model.depth == 1, "a step replaces the page; the palette never nests one level per folder")
        #expect(model.handle(.back))
        await Self.settle(model)
        #expect(model.selectedRowID == "dir:" + path("api"))
    }

    @Test func rightAndLeftAreTheDrillKeysOnlyOnATreePage() throws {
        let registry = ActionRegistry.standard()
        func key(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: code))
        }
        func command(_ code: UInt16, tree: Bool, empty: Bool = true, atEnd: Bool = true) throws -> PaletteKeyCommand? {
            PaletteKeyMap.command(for: try key(code), actionsMenuOpen: false, queryIsEmpty: empty, registry: registry,
                                  hierarchical: tree, caretAtEnd: atEnd)
        }
        #expect(try command(124, tree: true) == .enterRow)
        #expect(try command(124, tree: true, empty: false, atEnd: true) == .enterRow)
        #expect(try command(124, tree: true, empty: false, atEnd: false) == nil, "Right moves the caret inside the query")
        #expect(try command(123, tree: true) == .leaveLevel)
        #expect(try command(123, tree: true, empty: false) == nil)
        #expect(try command(124, tree: false) == nil)
        #expect(try command(123, tree: false) == nil)
    }

    /// The list keys are the palette's own (R85 routes them through the
    /// registry's Palette Next/Previous actions): the picker adds no key
    /// handling of its own.
    @Test func ctrlNAndCtrlPMoveTheListThroughTheRegistry() async throws {
        let registry = ActionRegistry.standard()
        func key(_ code: UInt16, _ chars: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0,
                                          context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                                          keyCode: code))
        }
        let (model, _, _) = await open(.file(.any))
        let next = try #require(PaletteKeyMap.command(for: try key(45, "n"), actionsMenuOpen: false, queryIsEmpty: true,
                                                      registry: registry, hierarchical: true))
        #expect(next == .moveDown)
        model.handle(next)
        #expect(model.selectedRowID == "dir:" + path("docs"))
        let previous = try #require(PaletteKeyMap.command(for: try key(35, "p"), actionsMenuOpen: false, queryIsEmpty: true,
                                                          registry: registry, hierarchical: true))
        model.handle(previous)
        #expect(model.selectedRowID == "dir:" + path("api"))
    }

    @Test func typingFiltersTheLevelAndHidesDotEntriesUnlessTheQueryStartsWithADot() async {
        let (model, _, _) = await open(.file(.any))
        #expect(!ids(model).contains("dir:" + path(".config")))
        model.query = "conf"
        await model.settle()
        #expect(!ids(model).contains("dir:" + path(".config")))
        model.query = ".con"
        await model.settle()
        #expect(ids(model).first == "dir:" + path(".config"))
        model.query = "rdme"
        await model.settle()
        #expect(ids(model).first == "file:" + path("README.md"))
    }

    @Test func returnChoosesAFileAndEntersAFolderInFileMode() async {
        let (model, answer, _) = await open(.file(.markdown))
        #expect(!ids(model).contains("file:" + path("main.swift")))
        model.query = "readme"
        await model.settle()
        model.handle(.submit)
        #expect(answer.urls == .some([root.appendingPathComponent("README.md")]))
    }

    @Test func folderModeUsesThisFolderAndReturnChoosesASubfolder() async {
        let (model, answer, _) = await open(.folder)
        #expect(ids(model).first == "use")
        #expect(!ids(model).contains { $0.hasPrefix("file:") })
        model.handle(.moveDown)
        model.handle(.submit)
        #expect(answer.urls == .some([URL(fileURLWithPath: path("api"), isDirectory: true)]))
        let (again, chosen, _) = await open(.folder)
        again.handle(.submit)
        #expect(chosen.urls == .some([URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)]))
    }

    /// Typing filters, always: `~` alone is text, not a jump.
    @Test func tildeFiltersAndNeverJumps() async {
        let (model, _, _) = await open(.folder, at: root.appendingPathComponent("api"))
        model.query = "~"
        await model.settle()
        #expect(model.currentPageID == "picker")
        #expect(model.pageTitle.hasSuffix("api"))
        #expect(model.query == "~")
    }

    @Test func locationsShowAtTheStartForAnEmptyQueryOnly() async {
        let web = URL(fileURLWithPath: path("web"), isDirectory: true)
        let (model, _, _) = await open(.file(.any), recents: [path("docs/guide.md")],
                                       locations: [PickerLocation(kind: .pinned, url: web)])
        let pinned = "loc:0:" + web.path
        #expect(Array(ids(model).prefix(2)) == ["loc:recent", pinned])
        model.query = "w"
        await model.settle()
        #expect(!ids(model).contains(pinned), "typing filters the folder, not the locations")
        model.query = ""
        await model.settle()
        model.send(.select(pinned))
        model.handle(.openActions)
        await Self.settle(model)
        #expect(model.pageTitle.hasSuffix("web"))
        #expect(!ids(model).contains(pinned), "locations show at the start folder only")
    }

    @Test func recentIsAPlaceToEnterAndLeave() async {
        let (model, answer, _) = await open(.file(.any), recents: [path("web") + "/", path("README.md"), path("main.swift")])
        model.send(.select("loc:recent"))
        model.handle(.openActions)
        await Self.settle(model)
        #expect(model.currentPageID == "picker.recent")
        #expect(model.rows.map(\.item.title) == ["web", "README.md", "main.swift"])
        #expect(model.handle(.back))
        await Self.settle(model)
        #expect(model.currentPageID == "picker")
        model.send(.select("loc:recent"))
        model.handle(.submit)
        await Self.settle(model)
        model.send(.select("file:" + path("README.md")))
        model.handle(.submit)
        #expect(answer.urls == .some([URL(fileURLWithPath: path("README.md"))]))
    }

    @Test func cmdUpAndTheBreadcrumbGoUp() async throws {
        let registry = ActionRegistry.standard()
        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad],
                                               timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                               isARepeat: false, keyCode: 126))
        #expect(PaletteKeyMap.command(for: up, actionsMenuOpen: false, queryIsEmpty: false, registry: registry, hierarchical: true) == .leaveLevel)
        #expect(PaletteKeyMap.command(for: up, actionsMenuOpen: false, queryIsEmpty: false, registry: registry) == .moveToFirst)
        let (model, _, _) = await open(.folder, at: root.appendingPathComponent("api/src"))
        #expect(model.pageCrumbs == ["~", "api", "src"])
        #expect(model.fieldHint == PickerStrings.openHint)
        model.handle(.leaveLevel)
        await Self.settle(model)
        #expect(model.pageTitle.hasSuffix("api"))
        model.openCrumb(at: 0)
        await Self.settle(model)
        #expect(model.pageTitle == "~")
    }

    /// As the webviews picker: Escape clears the query first, and only a
    /// second Escape pops the pushed picker back to the commands.
    @Test func escapeClearsTheQueryThenPopsThePage() async {
        let answer = Answer()
        let model = PaletteModel(persistence: InMemoryFrecencyPersistence())
        model.reset(to: PalettePageSpec(id: "commands", title: "Commands", placeholder: "Search",
                                        providers: [StaticPaletteProvider(id: "static", items: [])]))
        let session = PickerSession(environment: PickerEnvironment(home: root)) { answer.urls = .some($0) }
        model.push(session.page(for: FolderPickerState(mode: .folder, start: root)))
        await Self.settle(model)
        #expect(model.depth == 2)
        model.query = "we"
        await model.settle()
        model.handle(.escape)
        #expect(model.query.isEmpty)
        #expect(model.depth == 2, "the first Escape only clears the query")
        model.handle(.escape)
        #expect(model.depth == 1, "the second Escape pops the picker")
        #expect(answer.urls == .some(nil))
    }

    @Test func leavingThePaletteAnswersNil() async {
        let (model, answer, _) = await open(.folder)
        model.handle(.escape)
        model.didHide()
        #expect(answer.urls == .some(nil))
    }

    @Test func cmdReturnMarksSeveralAndReturnChoosesThemAll() async {
        let mode = PickerMode(kind: .open(.files), allowsMultiple: true)
        let (model, answer, session) = await open(mode)
        model.send(.select("file:" + path("main.swift")))
        model.handle(.submitAlternate)
        await Self.settle(model)
        #expect(session.marked == [root.appendingPathComponent("main.swift")])
        #expect(ids(model).first == "picker.openMarked")
        model.send(.select("file:" + path("README.md")))
        model.handle(.submit)
        #expect(answer.urls == .some([root.appendingPathComponent("main.swift"), root.appendingPathComponent("README.md")]))
    }

    @Test func theExplainerShowsOnceBeforeTheFirstProtectedFolder() async {
        let memory = Memory()
        let documents = root.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: documents.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let (model, _, session) = await open(.folder, home: root, memory: memory)
        model.send(.select("dir:" + path("Documents")))
        model.handle(.openActions)
        await Self.settle(model)
        #expect(ids(model).contains("explainer.continue"))
        #expect(memory.hasShownExplainer)
        model.handle(.submit)
        await Self.settle(model)
        #expect(ids(model).contains("dir:" + path("Documents/notes")))
        // Shown once: the next protected folder lists at once.
        let downloads = FolderPickerState(mode: .folder, start: root.appendingPathComponent("Downloads"))
        #expect(session.page(for: downloads).id == "picker")
    }

    @Test func aFolderMadeWithNewFolderOpens() async throws {
        let (model, _, _) = await open(.folder)
        model.send(.select("picker.newFolder"))
        model.handle(.submit)
        #expect(model.isTextInput)
        model.query = "fresh"
        model.handle(.submit)
        await Self.settle(model)
        #expect(FileManager.default.fileExists(atPath: path("fresh")))
        #expect(model.pageTitle.hasSuffix("fresh"))
        #expect(model.depth == 1)
    }
}
