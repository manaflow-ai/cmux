import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

@MainActor
@Suite struct ShortcutBindingTests {
    @Test func parsesTheOldAppFormats() {
        #expect(ShortcutBindingFormat.parse("cmd+shift+p") == .stroke(ShortcutStrokeSpec(key: "p", command: true, shift: true)))
        #expect(ShortcutBindingFormat.parse("⌘⇧+P") == nil)  // glyphs must be `+`-separated
        #expect(ShortcutBindingFormat.parse("⌘+⇧+P") == .stroke(ShortcutStrokeSpec(key: "p", command: true, shift: true)))
        #expect(ShortcutBindingFormat.parse("ctrl+opt+left") == .stroke(ShortcutStrokeSpec(key: Shortcut.leftArrowKey, option: true, control: true)))
        #expect(ShortcutBindingFormat.parse("cmd+return") == .stroke(ShortcutStrokeSpec(key: "\r", command: true)))
        #expect(ShortcutBindingFormat.parse("cmd+backslash") == .stroke(ShortcutStrokeSpec(key: "\\", command: true)))
        #expect(ShortcutBindingFormat.parse("f5") == .stroke(ShortcutStrokeSpec(key: String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)))))
        #expect(ShortcutBindingFormat.parse(.null) == .unbound)
        for token in ["", "none", "clear", "unbound", "disabled", "Disabled"] {
            #expect(ShortcutBindingFormat.parse(.string(token)) == .unbound, "\(token)")
        }
        #expect(ShortcutBindingFormat.parse(["ctrl+b", "c"]) == .chord(ShortcutStrokeSpec(key: "b", control: true), ShortcutStrokeSpec(key: "c")))
        #expect(ShortcutBindingFormat.parse(["cmd+k"]) == .stroke(ShortcutStrokeSpec(key: "k", command: true)))
        #expect(ShortcutBindingFormat.parse(["cmd+k", "x", "y"]) == nil)
        #expect(ShortcutBindingFormat.parse("hyper+k") == nil)
        #expect(ShortcutBindingFormat.parse(["first": ["key": "d", "command": true, "shift": true]]) == .stroke(ShortcutStrokeSpec(key: "d", command: true, shift: true)))
        #expect(ShortcutBindingFormat.parse(["first": ["key": ""]]) == .unbound)
    }

    @Test func configStringsRoundTrip() {
        for text in ["cmd+shift+p", "ctrl+opt+left", "cmd+return", "cmd+\\", "opt+f12", "cmd+space"] {
            guard case .stroke(let stroke) = ShortcutBindingFormat.parse(.string(text)) else {
                Issue.record("\(text) did not parse")
                continue
            }
            #expect(ShortcutBindingFormat.parse(.string(ShortcutBindingFormat.configString(stroke))) == .stroke(stroke), "\(text)")
        }
    }
}

@Suite struct SnapshotTests {
    let densities: Set<String> = ["compact", "comfortable"]
    let metrics: Set<String> = ["sidebarWidth", "tabStripHeight"]

    @Test func parsesAppearanceAndShortcuts() throws {
        let root = try JSONC.parse("""
        {
          "appearance": { "density": "comfortable", "metrics": { "sidebarWidth": 260, "bogus": 1, "tabStripHeight": "tall" } },
          "shortcuts": {
            "showModifierHoldHints": false,
            "bindings": { "splitRight": "cmd+\\\\", "splitDown": "cmd+shift+d" },
            "splitDown": null,
            "when": { "splitRight": "terminalFocused" }
          }
        }
        """)
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: densities, validMetrics: metrics)
        #expect(snapshot.density == "comfortable")
        #expect(snapshot.metrics == ["sidebarWidth": 260])
        #expect(snapshot.shortcuts["splitRight"] == .stroke(ShortcutStrokeSpec(key: "\\", command: true)))
        // Direct `shortcuts.<id>` keys win over `bindings`, like the old loader.
        #expect(snapshot.shortcuts["splitDown"] == .unbound)
        #expect(snapshot.shortcuts["when"] == nil && snapshot.shortcuts["showModifierHoldHints"] == nil)
        #expect(snapshot.diagnostics.map(\.path) == ["appearance.metrics.bogus", "appearance.metrics.tabStripHeight"])
    }

    @Test func reportsBadDensity() {
        let snapshot = CmuxConfigSnapshot.parse(["appearance": ["density": "roomy"]], validDensities: densities, validMetrics: metrics)
        #expect(snapshot.density == nil)
        #expect(snapshot.diagnostics.first?.kind == .invalidValue)
    }
}

@MainActor
@Suite struct ApplierTests {
    @Test func appliesAndRevertsFileSettings() throws {
        let design = DesignSettings()
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: design, registry: registry)
        let root = try JSONC.parse("""
        {"appearance": {"density": "comfortable", "metrics": {"sidebarWidth": 999}},
         "shortcuts": {"bindings": {"splitRight": "cmd+\\\\", "splitDown": null, "tab.new": "cmd+shift+t", "nope": "cmd+k",
                                    "toggleSidebar": ["ctrl+b", "s"]}}}
        """)
        let diagnostics = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))

        #expect(design.density == .comfortable)
        #expect(design.overrides[.sidebarWidth] == 420)  // clamped
        #expect(registry.effectiveShortcut(for: "splitRight") == Shortcut("\\", modifiers: [.command]))
        #expect(registry.effectiveShortcut(for: "splitDown") == nil)
        // Legacy alias `tab.new` folds into `newSurface`.
        #expect(registry.effectiveShortcut(for: "newSurface") == Shortcut("t", modifiers: [.command, .shift]))
        #expect(diagnostics.contains { $0.kind == .unknownAction && $0.path == "shortcuts.bindings.nope" })
        #expect(diagnostics.contains { $0.kind == .unsupportedChord && $0.path == "shortcuts.bindings.toggleSidebar" })

        // Removing everything from the file restores defaults.
        applier.apply(CmuxConfigSnapshot.parse(.object([:]), validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))
        #expect(design.density == .compact)
        #expect(design.overrides.isEmpty)
        #expect(registry.shortcutDisplay(for: "splitRight") == "⌘D")
        #expect(registry.shortcutDisplay(for: "splitDown") == "⇧⌘D")
    }

    @Test func reportsConflicts() throws {
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        let root: JSONValue = ["shortcuts": ["bindings": ["splitDown": "cmd+d"]]]
        let diagnostics = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []))
        let conflict = try #require(diagnostics.first { $0.kind == .shortcutConflict })
        #expect(conflict.message.contains("splitRight") && conflict.message.contains("splitDown"))
    }

    @Test func unreadableFileKeepsLastGoodState() {
        let design = DesignSettings()
        design.density = .comfortable
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        var broken = CmuxConfigSnapshot.empty
        broken.diagnostics = [SettingsDiagnostic(kind: .unreadableFile, path: "", message: "bad")]
        applier.apply(broken)
        #expect(design.density == .comfortable)
    }
}

/// End-to-end: file on disk -> watcher -> applied settings, and writes back.
@MainActor
@Suite(.serialized) struct SettingsControllerTests {
    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-next-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Waits for the next load, failing instead of hanging.
    func nextLoad(_ controller: SettingsController, after count: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await controller.waitForLoad(atLeast: count + 1) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw CancellationError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Waits until `condition` holds after file events settle.
    func eventually(_ controller: SettingsController, _ label: String = #function, line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<20 where !condition() {
            do {
                try await nextLoad(controller, after: controller.loadCount)
            } catch {
                Issue.record("timed out waiting at line \(line)")
                throw error
            }
        }
        #expect(condition())
    }

    @Test func watchesEverySaveStyle() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The config directory does not exist yet; the watcher must notice it.
        let url = directory.appending(path: "config/cmux/cmux.json")
        let design = DesignSettings()
        let registry = ActionRegistry.standard()
        let controller = SettingsController(registry: registry, design: design, fileURL: url)
        controller.start()
        defer { controller.stop() }
        try await nextLoad(controller, after: 0)
        #expect(design.density == .compact)

        // Create (directory and file appear).
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"appearance": {"density": "comfortable"}}"#.utf8).write(to: url)
        try await eventually(controller) { design.density == .comfortable }

        // In-place write.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"appearance": {"density": "compact"}, "shortcuts": {"splitRight": "cmd+\\"}}"#.utf8))
        try handle.close()
        try await eventually(controller) { design.density == .compact && registry.shortcutDisplay(for: "splitRight") == "⌘\\" }

        // Atomic rename over the file (how most editors save).
        try Data(#"{"appearance": {"metrics": {"sidebarWidth": 300}}}"#.utf8).write(to: url, options: .atomic)
        try await eventually(controller) { design.overrides[.sidebarWidth] == 300 && registry.shortcutDisplay(for: "splitRight") == "⌘D" }

        // Delete: defaults come back.
        try FileManager.default.removeItem(at: url)
        try await eventually(controller) { design.overrides.isEmpty }
    }

    @Test func writesPreserveCommentsAndApplyThroughTheWatcher() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("// my settings\n{\n  \"terminal\": {\"fontSize\": 13}, // keep\n}\n".utf8).write(to: url)
        let design = DesignSettings()
        let registry = ActionRegistry.standard()
        let controller = SettingsController(registry: registry, design: design, fileURL: url)
        controller.start()
        defer { controller.stop() }
        try await nextLoad(controller, after: 0)

        try await controller.setShortcut(Shortcut("g", modifiers: [.command, .shift]), for: "tabGroup.create")
        try await controller.setDensity(.comfortable)
        try await eventually(controller) {
            registry.shortcutDisplay(for: "tabGroup.create") == "⇧⌘G" && design.density == .comfortable
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("// my settings\n"))
        #expect(text.contains("// keep"))
        #expect(text.contains("\"tabGroup.create\": \"cmd+shift+g\""))

        try await controller.resetShortcut(for: "tabGroup.create")
        try await eventually(controller) { registry.shortcutDisplay(for: "tabGroup.create") == nil }
    }

    @Test func refusesToRewriteABrokenFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{ \"a\": ".utf8).write(to: url)
        let file = CmuxConfigFile(url: url)
        await #expect(throws: CmuxConfigFile.Failure.self) { try await file.set(1, at: ["b"]) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ \"a\": ")
    }

    @Test func writesThroughASymlink() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "dotfiles-cmux.json")
        try Data("{}".utf8).write(to: real)
        let link = directory.appending(path: "cmux.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try await CmuxConfigFile(url: link).set("dark", at: ["app", "appearance"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try JSONC.parse(String(contentsOf: real, encoding: .utf8)).value(at: ["app", "appearance"]) == "dark")
    }
}
