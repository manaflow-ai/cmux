import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Foundation
import Testing

/// The Settings window's model: edits write cmux.json and apply live,
/// external edits show up through the file watcher, search spans sections
/// and shortcuts, and the Keyboard section runs the palette's recorder.
@MainActor
@Suite struct SettingsWindowModelTests {
    final class Editor: ShortcutRecorderEditing {
        var saves: [[ShortcutChange]] = []
        func environment(for event: NSEvent?) -> ShortcutEditEnvironment { ShortcutEditEnvironment() }
        func save(_ changes: [ShortcutChange]) { saves.append(changes) }
        func restoreDefault(_ id: ActionID, unbinding others: [ActionID]) {}
    }

    struct Harness {
        let model: SettingsWindowModel
        let url: URL
        let design: DesignSettings
        let host: MockSettingsWindowHost
        let editor: Editor
    }

    func harness(_ text: String = "{}\n") async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-settings-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "a.first", title: "First Action", defaultShortcut: Shortcut("g", modifiers: [.command]), category: .workspace),
            ActionDescriptor(id: "a.second", title: "Second Action", defaultShortcut: Shortcut("u", modifiers: [.command]), category: .tab),
            ActionDescriptor(id: "a.unbound", title: "Unbound Action", category: .tab, surfaces: [.palette, .keyboard]),
        ])
        for descriptor in registry.descriptors { registry.bind(descriptor.id) {} }
        let design = DesignSettings()
        let settings = SettingsController(registry: registry, design: design, fileURL: url)
        settings.start()
        await settings.waitForLoad(atLeast: 1)
        let host = MockSettingsWindowHost()
        let editor = Editor()
        host.shortcutEditor = editor
        return Harness(model: SettingsWindowModel(settings: settings, registry: registry, host: host), url: url,
                       design: design, host: host, editor: editor)
    }

    func descriptor(_ path: String) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: path.split(separator: ".").map(String.init)))
    }

    func document(_ url: URL) throws -> JSONValue { try JSONC.parse(String(contentsOf: url, encoding: .utf8)) }

    @Test func anEditShowsAtOnceWritesTheFileAndAppliesLive() async throws {
        let h = try await harness()
        defer { h.model.settings.stop() }
        let speed = try descriptor("ui.animationSpeed")
        h.model.set(speed, "off")
        #expect(h.model.value(speed) == "off")
        await h.model.settled()
        #expect(try document(h.url).value(at: ["ui", "animationSpeed"]) == "off")
        #expect(h.design.animationSpeed == .off)
        h.model.set(speed, nil)
        await h.model.settled()
        #expect(try document(h.url)["ui"] == nil)
        #expect(h.design.animationSpeed == .fast)
    }

    @Test func anExternalEditUpdatesTheWindow() async throws {
        let h = try await harness()
        defer { h.model.settings.stop() }
        let density = try descriptor("appearance.density")
        #expect(h.model.value(density) == "compact")
        try Data(#"{ "appearance": { "density": "comfortable" } }"#.utf8).write(to: h.url, options: .atomic)
        // Only the file watcher reloads here (no explicit reload); give up after 5 s.
        let model = h.model
        let waiter = Task { @MainActor in
            while !Task.isCancelled, model.value(density) != "comfortable" {
                await model.settings.waitForLoad(atLeast: model.settings.loadCount + 1)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(5))
            waiter.cancel()
        }
        await waiter.value
        timer.cancel()
        #expect(h.model.value(density) == "comfortable")
        #expect(h.model.isCustomized(density))
    }

    @Test func aBadValueInTheFileShowsItsDiagnosticAndTheDefault() async throws {
        let h = try await harness(#"{ "layout": { "paneBorder": "thick" } }"#)
        defer { h.model.settings.stop() }
        let border = try descriptor("layout.paneBorder")
        #expect(h.model.value(border) == "subtle")
        #expect(h.model.diagnostic(border) != nil)
    }

    @Test func searchSpansSectionsAndShortcuts() async throws {
        let h = try await harness()
        defer { h.model.settings.stop() }
        h.model.query = "animations"
        #expect(h.model.searchResults().flatMap(\.settings).map(\.id) == ["ui.animationSpeed"])
        h.model.query = "second"
        #expect(h.model.shortcutSections().flatMap(\.rows).map(\.id) == ["a.second"])
        h.model.query = ""
        let all = h.model.shortcutSections().flatMap(\.rows).map(\.id)
        #expect(Set(all) == ["a.first", "a.second", "a.unbound"])
    }

    @Test func theRecorderOffersReplaceOnAConflictAndSavesBoth() async throws {
        let h = try await harness()
        defer { h.model.settings.stop() }
        #expect(h.model.beginRecording("a.first"))
        h.model.handleRecorderKey(Shortcut("u", modifiers: [.command]))
        let state = try #require(h.model.recorder)
        #expect(state.pending?.owners == ["a.second"])
        #expect(state.message?.contains("Second Action") == true)
        #expect(state.options.contains(.replace))
        h.model.chooseRecorderOption(.replace)
        #expect(h.model.recorder == nil)
        #expect(h.editor.saves == [[ShortcutChange("a.first", Shortcut("u", modifiers: [.command])), ShortcutChange("a.second", nil)]])
        #expect(h.model.notice?.actionID == "a.first")
        #expect(h.model.registry.effectiveShortcut(for: "a.second") == nil)
    }

    @Test func theRecorderRefusesAChordWithoutCommandOrControl() async throws {
        let h = try await harness()
        defer { h.model.settings.stop() }
        h.model.beginRecording("a.unbound")
        h.model.handleRecorderKey(Shortcut("k", modifiers: [.option]))
        #expect(h.model.recorder?.pending == nil)
        #expect(h.model.recorder?.message != nil)
        #expect(h.editor.saves.isEmpty)
        h.model.handleRecorderKey(Shortcut("", modifiers: []), keyCode: 53)
        #expect(h.model.recorder == nil)
    }

    @Test func everySectionTitleAndActionIsKnown() {
        for section in SettingsSection.allCases {
            #expect(!section.title.isEmpty)
        }
        let catalog = ActionRegistry(catalog: ActionCatalog.all)
        for section in SettingsSection.allCases {
            for id in SettingsSchema.actions(in: section) {
                #expect(catalog.descriptor(for: id) != nil, "\(section): \(id.rawValue)")
            }
        }
    }

    /// `cmux action run openSettings --arg section=keyboard` names the same
    /// sections the window shows.
    @Test func openSettingsSectionsAreTheWindowSections() throws {
        let descriptor = try #require(ActionRegistry(catalog: ActionCatalog.all).descriptor(for: "openSettings"))
        let argument = try #require(descriptor.arguments.first { $0.name == "section" })
        guard case .enumeration(let cases) = argument.kind else {
            Issue.record("section is not an enumeration")
            return
        }
        #expect(cases.map(\.value) == SettingsSection.allCases.map(\.rawValue))
        #expect(!argument.isRequired)
    }
}
