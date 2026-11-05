import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The All Themes playground is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): no hosting view, one
/// table row per theme the filter shows, and the search field and "Failures only" box filter it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AllThemesPlaygroundViewTests {
    /// A folder with a readable theme (black on white) and an unreadable one (grey on grey).
    private func themes() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("background = #ffffff\nforeground = #000000\n".utf8).write(to: folder.appendingPathComponent("Paper"))
        try Data("background = #777777\nforeground = #808080\n".utf8).write(to: folder.appendingPathComponent("Fog"))
        return folder
    }

    private func loaded() async throws -> (AllThemesPlaygroundModel, AllThemesPlaygroundView) {
        let folder = try themes()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AllThemesPlaygroundModel()
        await model.load(folders: [folder])
        let view = AllThemesPlaygroundView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.render()
        view.layoutSubtreeIfNeeded()
        return (model, view)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func control<T: NSView>(_ type: T.Type, _ identifier: String, in view: NSView) throws -> T {
        try #require(descendants(of: view).compactMap { $0 as? T }.first { $0.accessibilityIdentifier() == identifier })
    }

    @Test func showsEveryThemeWithoutHosting() async throws {
        let (model, view) = try await loaded()
        #expect(model.entries.count == 2)
        #expect(view.rowCount == 2)
        #expect(view.summaryText == AllThemesPlaygroundStrings.summary(failing: model.failingCount, total: 2))
        #expect(!descendants(of: view).contains { String(describing: type(of: $0)).contains("Hosting") })
    }

    @Test func failuresOnlyBoxShowsOnlyFailingThemes() async throws {
        let (model, view) = try await loaded()
        let box = try control(NSButton.self, "cmux.allThemesPlayground.failuresOnly", in: view)
        box.performClick(nil)
        #expect(model.failuresOnly)
        #expect(view.rowCount == model.entries.filter { !$0.failures.isEmpty }.count)
        #expect(view.shown.allSatisfy { !$0.failures.isEmpty })
        box.performClick(nil)
        #expect(!model.failuresOnly)
        #expect(view.rowCount == 2)
    }

    @Test func searchFieldFiltersByName() async throws {
        let (model, view) = try await loaded()
        let field = try control(NSTextField.self, "cmux.allThemesPlayground.search", in: view)
        field.stringValue = "pap"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(model.query == "pap")
        #expect(view.shown.map(\.name) == ["Paper"])
        #expect(view.rowCount == 1)
    }

    @Test func rowHeightGrowsWhenChipsWrap() async throws {
        let (model, _) = try await loaded()
        let entry = try #require(model.entries.first)
        let wide = AllThemesPlaygroundRow.height(of: entry, width: 4000)
        let narrow = AllThemesPlaygroundRow.height(of: entry, width: 400)
        #expect(narrow >= wide)
        if entry.samples.count > AllThemesPlaygroundRow.chipsPerLine(width: 400) { #expect(narrow > wide) }
    }
}
