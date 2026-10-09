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

@MainActor
@Suite struct ApplierTests {
    /// The per-kind new-tab chords (#16620) are the user's from the start:
    /// cmux.json rebinds or unbinds each one like any other action.
    @Test func eachKindsNewTabChordIsTheUsers() throws {
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        #expect(registry.effectiveShortcut(for: "palette.newAgentChat") == Shortcut("i", modifiers: [.command]))
        #expect(registry.effectiveShortcut(for: "newSurface") == Shortcut("`", modifiers: [.control]))
        let root = try JSONC.parse("""
        {"shortcuts": {"bindings": {"palette.newAgentChat": "cmd+opt+shift+y", "newSurface": null, "openBrowser": "ctrl+cmd+b"}}}
        """)
        _ = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))
        #expect(registry.effectiveShortcut(for: "palette.newAgentChat") == Shortcut("y", modifiers: [.command, .option, .shift]))
        #expect(registry.effectiveShortcut(for: "newSurface") == nil)
        #expect(registry.effectiveShortcut(for: "openBrowser") == Shortcut("b", modifiers: [.control, .command]))
    }

    /// The Terminal.app base keymap renames tabs with Cmd-Shift-I, so Show
    /// Feed moves to Ctrl-Cmd-Shift-I while New Agent Chat keeps Cmd-I.
    @Test func theTerminalPresetMovesNewAgentChatAside() throws {
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        let bindings = Dictionary(uniqueKeysWithValues: ShortcutKeymapPreset.terminal.overrides.map { ($0.key, $0.value) })
        let root = JSONValue.object(["shortcuts": .object(["bindings": .object(bindings)])])
        _ = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))
        #expect(registry.effectiveShortcut(for: "renameTab") == Shortcut("i", modifiers: [.command, .shift]))
        #expect(registry.effectiveShortcut(for: "feed.show") == Shortcut("i", modifiers: [.control, .command, .shift]))
        #expect(registry.effectiveShortcut(for: "palette.newAgentChat") == Shortcut("i", modifiers: [.command]))
        #expect(!registry.shortcutConflicts().contains {
            $0.contains("feed.show") || $0.contains("palette.newAgentChat") || $0.contains("renameTab")
        })
    }

    @Test func appliesAndRevertsFileSettings() throws {
        let design = DesignSettings()
        let registry = ActionRegistry.standard()
        let applier = SettingsApplier(design: design, registry: registry)
        let root = try JSONC.parse("""
        {"appearance": {"density": "comfortable", "metrics": {"sidebarWidth": 999}},
         "shortcuts": {"bindings": {"splitRight": "cmd+\\\\", "splitDown": null, "tab.new": "cmd+shift+t", "nope": "cmd+k",
                                    "toggleSidebar": ["ctrl+b", "s"], "newTab": ["b", "c"]}}}
        """)
        let diagnostics = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))

        #expect(design.density == .comfortable)
        #expect(design.overrides[.sidebarWidth] == 420)  // clamped
        #expect(registry.effectiveShortcut(for: "splitRight") == Shortcut("\\", modifiers: [.command]))
        #expect(registry.effectiveShortcut(for: "splitDown") == nil)
        // Legacy alias `tab.new` folds into `newSurface`.
        #expect(registry.effectiveShortcut(for: "newSurface") == Shortcut("t", modifiers: [.command, .shift]))
        #expect(diagnostics.contains { $0.kind == .unknownAction && $0.path == "shortcuts.bindings.nope" })
        #expect(registry.effectiveChord(for: "toggleSidebar") == ShortcutChord(Shortcut("b", modifiers: [.control]), Shortcut("s", modifiers: [])))
        #expect(registry.effectiveShortcut(for: "toggleSidebar") == nil)
        #expect(registry.shortcutDisplay(for: "toggleSidebar") == "⌃B S")
        // A chord's first key needs Command or Control.
        #expect(diagnostics.contains { $0.kind == .unsupportedChord && $0.path == "shortcuts.bindings.newTab" })
        #expect(registry.effectiveChord(for: "newTab") == nil)

        // Removing everything from the file restores defaults.
        applier.apply(CmuxConfigSnapshot.parse(.object([:]), validDensities: SettingsApplier.validDensities, validMetrics: SettingsApplier.validMetrics))
        #expect(design.density == .compact)
        #expect(design.overrides.isEmpty)
        #expect(registry.shortcutDisplay(for: "splitRight") == "⌘D")
        #expect(registry.shortcutDisplay(for: "splitDown") == "⇧⌘D")
        #expect(registry.effectiveChord(for: "toggleSidebar") == nil)
        #expect(registry.effectiveShortcut(for: "toggleSidebar") != nil)
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

