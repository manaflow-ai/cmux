import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Foundation
import Testing

/// Cmd-P and Cmd-Shift-P read a typed path or web address and put Open and
/// Ask Agent rows first, above the usual results.
@MainActor
@Suite(.paletteRanker, .closesItsWindows)
struct PaletteGoToTests {
    /// A fake disk: these paths exist, folders end in "/".
    private nonisolated static func fakeKind(_ path: String) -> PaletteQueryTargetParser.Kind? {
        let disk: Set<String> = ["/Users/me/", "/Users/me/code/", "/Users/me/code/app/", "/Users/me/code/app/README.md",
                                 "/Users/me/My Notes.md", "/tmp/"]
        if disk.contains(path + "/") { return .folder }
        if disk.contains(path) { return .file }
        return nil
    }

    private static var parser: PaletteQueryTargetParser {
        PaletteQueryTargetParser(home: "/Users/me", kind: { fakeKind($0) })
    }

    private static func parse(_ query: String, base: String? = "/Users/me/code") -> PaletteQueryMatch? {
        parser.parse(query, base: base)
    }

    // MARK: Paths

    @Test func absoluteHomeAndRelativePaths() {
        #expect(Self.parse("/Users/me/code/app/README.md")?.target == .file(URL(fileURLWithPath: "/Users/me/code/app/README.md")))
        #expect(Self.parse("~/code")?.target == .folder(URL(fileURLWithPath: "/Users/me/code", isDirectory: true)))
        #expect(Self.parse("~")?.target == .folder(URL(fileURLWithPath: "/Users/me", isDirectory: true)))
        #expect(Self.parse("./app")?.target == .folder(URL(fileURLWithPath: "/Users/me/code/app", isDirectory: true)))
        #expect(Self.parse("app/README.md")?.target == .file(URL(fileURLWithPath: "/Users/me/code/app/README.md")))
        #expect(Self.parse("..")?.target == .folder(URL(fileURLWithPath: "/Users/me", isDirectory: true)))
        #expect(Self.parse("README.md", base: "/Users/me/code/app")?.target == .file(URL(fileURLWithPath: "/Users/me/code/app/README.md")))
        #expect(Self.parse("file:///tmp")?.target == .folder(URL(fileURLWithPath: "/tmp", isDirectory: true)))
    }

    @Test func plainWordsAndMissingPathsAreNoPlace() {
        // A bare word is a search, even when a folder of that name exists.
        #expect(Self.parse("app") == nil)
        #expect(Self.parse("build failing") == nil)
        #expect(Self.parse("/no/such/file") == nil)
        #expect(Self.parse("./missing") == nil)
        // A relative path without a pane folder has nothing to start from.
        #expect(Self.parse("app/README.md", base: nil) == nil)
        #expect(Self.parse("   ") == nil)
    }

    @Test func pathWithSpacesWinsOverTrailingText() {
        #expect(Self.parse("~/My Notes.md") == PaletteQueryMatch(target: .file(URL(fileURLWithPath: "/Users/me/My Notes.md"))))
    }

    @Test func wordsAfterThePlaceAreThePrompt() {
        let match = Self.parse("~/code/app  why does the build fail? ")
        #expect(match?.target == .folder(URL(fileURLWithPath: "/Users/me/code/app", isDirectory: true)))
        #expect(match?.trailingText == "why does the build fail?")
        #expect(Self.parse("github.com/x summarize")?.trailingText == "summarize")
    }

    // MARK: Web addresses

    @Test(arguments: [
        ("https://github.com/manaflow-ai/cmux", "https://github.com/manaflow-ai/cmux"),
        ("http://example.org", "http://example.org"),
        ("github.com/x", "https://github.com/x"),
        ("example.com", "https://example.com"),
        ("docs.rs/tokio", "https://docs.rs/tokio"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost/admin", "http://localhost/admin"),
        ("10.0.0.2:8080/x", "http://10.0.0.2:8080/x"),
        ("api.dev.example.io:8443", "https://api.dev.example.io:8443"),
    ])
    func webAddresses(_ query: String, _ url: String) {
        #expect(Self.parse(query)?.target == .web(URL(string: url)!))
    }

    @Test(arguments: ["foo.swift", "notes.md", "localhost", "a.b", "v1.2.3", "https://", "foo..com", "-bad.com", "1.2.3.4.5", "host:abc"])
    func notWebAddresses(_ query: String) {
        #expect(Self.parse(query, base: nil) == nil)
    }

    @Test func anExistingPathWinsOverAHost() {
        // "README.md" could be a host on .md; it exists, so it is the file.
        #expect(Self.parse("README.md", base: "/Users/me/code/app")?.target == .file(URL(fileURLWithPath: "/Users/me/code/app/README.md")))
    }

    // MARK: Agent text

    @Test func agentTextNamesThePlaceThenThePrompt() {
        let file = PaletteQueryTarget.file(URL(fileURLWithPath: "/Users/me/code/app/README.md"))
        #expect(file.agentText(prompt: nil) == "/Users/me/code/app/README.md\n\n")
        #expect(file.agentText(prompt: "summarize") == "/Users/me/code/app/README.md\n\nsummarize")
        #expect(file.workingDirectory == "/Users/me/code/app")
        #expect(PaletteQueryTarget.web(URL(string: "https://x.dev")!).workingDirectory == nil)
    }

    // MARK: Rows

    @MainActor private final class GoTo: PaletteGoToSource {
        var base: String? = "/Users/me/code"
        var opened: [PaletteQueryTarget] = []
        var asked: [(PaletteQueryTarget, String?)] = []
        func baseDirectory() -> String? { base }
        func open(_ target: PaletteQueryTarget) { opened.append(target) }
        func askAgent(about target: PaletteQueryTarget, prompt: String?) { asked.append((target, prompt)) }
    }

    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace] = [PaletteWorkspace(id: "w1", title: "github.com/manaflow-ai notes", directory: nil, isSelected: false)]
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func run(_ command: PaletteCommand) {
        guard case .perform(let action) = command.effect else { Issue.record("not a perform effect"); return }
        action()
    }

    @Test func openAndAskRowsRunTheSource() {
        let source = GoTo()
        let rows = GoToPaletteRows(parser: Self.parser).items("~/code/app", source: source)
        #expect(rows.map(\.id) == ["goTo:open", "goTo:ask"])
        #expect(rows[0].title.contains("/Users/me/code/app"))
        Self.run(rows[0].primary)
        Self.run(rows[1].primary)
        let folder = PaletteQueryTarget.folder(URL(fileURLWithPath: "/Users/me/code/app", isDirectory: true))
        #expect(source.opened == [folder])
        #expect(source.asked.count == 1 && source.asked[0].0 == folder && source.asked[0].1 == nil)
    }

    @Test func trailingWordsPutAskFirstAndSendThem() {
        let source = GoTo()
        let rows = GoToPaletteRows(parser: Self.parser).items("github.com/x what changed", source: source)
        #expect(rows.map(\.id) == ["goTo:ask", "goTo:open"])
        Self.run(rows[0].primary)
        #expect(source.asked.first?.1 == "what changed")
        #expect(source.asked.first?.0 == .web(URL(string: "https://github.com/x")!))
    }

    @Test func noPlaceNoRows() {
        #expect(GoToPaletteRows(parser: Self.parser).items("manaflow notes", source: GoTo()).isEmpty)
        #expect(GoToPaletteRows(parser: Self.parser).items("~/code", source: nil).isEmpty)
    }

    @Test func bothPalettesShowTheRowsFirstAboveResults() async {
        _ = NSApplication.shared
        let source = GoTo()
        var sources = PaletteSources(workspaces: Workspaces())
        sources.goTo = source
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: sources, frecencyPersistence: nil)
        defer { palette.closeForTest() }
        for mode in [PaletteMode.commands, .workspaces] {
            palette.show(mode)
            palette.model.send(.setQuery("github.com/manaflow-ai"))
            await palette.model.settle()
            let ids = palette.model.rows.map(\.item.id)
            #expect(Array(ids.prefix(2)) == ["goTo:open", "goTo:ask"], "\(mode): \(ids)")
            #expect(ids.count > 2, "normal results stay below")
        }
    }
}
