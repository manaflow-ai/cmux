import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing
import CmuxNextFilesUI

/// The right sidebar's Find section and Open Find as Pane (classic's project-wide find): ripgrep
/// over the focused terminal's folder, one row per matching line, a result opening in cmux.
@MainActor @Suite(.serialized)
struct FindSectionTests {
    static let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    static let match = RipgrepMatch(path: "/tmp/project/Sources/App.swift", relativePath: "Sources/App.swift",
                                    line: 12, column: 5, preview: "let needle = 1")

    @Test func aSearchListsTheMatchesUnderTheRoot() async {
        var asked: [(String, String)] = []
        let model = FindSectionModel { query, root in
            asked.append((query, root))
            return .matches([Self.match], limited: false)
        }
        model.setRoot(Self.root)
        await model.search("needle")
        #expect(asked.map(\.0) == ["needle"])
        #expect(asked.map(\.1) == ["/tmp/project"])
        #expect(model.results == [Self.match])
        #expect(model.state == .done(limited: false))
    }

    @Test func anEmptyQueryClearsTheResultsWithoutSearching() async {
        var runs = 0
        let model = FindSectionModel { _, _ in
            runs += 1
            return .matches([Self.match], limited: false)
        }
        model.setRoot(Self.root)
        await model.search("needle")
        await model.search("   ")
        #expect(runs == 1)
        #expect(model.results.isEmpty)
        #expect(model.state == .idle)
    }

    @Test func withoutRipgrepTheSectionSaysSo() async {
        let model = FindSectionModel { _, _ in nil }
        model.setRoot(Self.root)
        await model.search("needle")
        #expect(model.state == .failed(FindInDirectoryStrings.ripgrepMissing))
    }

    @Test func aResultOpensInCmuxElseInItsApp() {
        let effects = FileExplorerTests.Recorder()
        FindSectionModel.open(Self.match, effects: effects)
        #expect(effects.openedInCmux == [URL(fileURLWithPath: Self.match.path)])
        effects.viewable = false
        FindSectionModel.open(Self.match, effects: effects)
        #expect(effects.openedInDefaultApp == [URL(fileURLWithPath: Self.match.path)])
    }

    /// A result opens its file at the matching line and column, not at the top.
    @Test func aResultOpensAtItsLineAndColumn() {
        let effects = FileExplorerTests.Recorder()
        FindSectionModel.open(Self.match, effects: effects)
        #expect(effects.openedInCmuxAt == [FilePosition(line: 12, column: 5)])
    }

    /// rg reports the match's start in UTF-8 bytes; the editor counts UTF-16 units, so a match
    /// after "é" (two bytes, one unit) is in column 3, not 4.
    @Test func aMatchColumnCountsUTF16Units() throws {
        let line = #"{"type":"match","data":{"path":{"text":"/tmp/project/a.txt"},"lines":{"text":"é needle\n"},"line_number":4,"submatches":[{"match":{"text":"needle"},"start":3,"end":9}]}}"#
        let match = try #require(RipgrepSearch.parse(line, root: "/tmp/project"))
        #expect(match.line == 4)
        #expect(match.column == 3)
    }

    @Test(arguments: ["switchRightSidebarToFind", "palette.openFindPane"])
    func theFindActionsAreWorkingActions(id: String) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil)
    }

    @Test func showFindShowsTheFindSection() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let suite = "cmux-find-section-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        services.rightSidebarDefaults = defaults
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["find-workspace"]))
        defer {
            for controller in services.windows.controllers { controller.window?.close() }
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(services.registry.perform("switchRightSidebarToFind", invocation: ActionInvocation(origin: .cli)))
        let panel = try #require(controller.root.rightPanel)
        #expect(panel.shownMode == .find)
        #expect(panel.shownSection is FindSectionView)
    }
}
