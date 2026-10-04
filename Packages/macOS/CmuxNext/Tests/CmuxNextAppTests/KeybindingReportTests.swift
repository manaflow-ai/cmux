import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The binding table's read ops (R59: `keybinding.list`,
/// `keybinding.resolve`, `context.keys`) as the socket, CLI and MCP return
/// them: keys in keybindings.json syntax, `when` as text, and every
/// candidate's verdict.
@MainActor
struct KeybindingReportTests {
    static let agent = KeyContext([KeyContext.surfaceKind: .string("agent"), "agentPaneFocused": .bool(true)])

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors { registry.bind(descriptor.id, invoke: { _ in }) }
        return registry
    }

    static func bindings(_ value: JSONValue) -> [[String: JSONValue]] {
        (value["bindings"]?.arrayValue ?? []).compactMap { if case .object(let entry) = $0 { entry } else { nil } }
    }

    @Test func listGivesKeysWhenTextAndSourceAndFilters() {
        let registry = Self.registry()
        let all = Self.bindings(KeybindingReports.list([:], registry: registry))
        let ctrlTab = all.first { $0["key"] == "ctrl+tab" && $0["command"] == "nextSurface" && $0["when"] == "surfaceKind != terminal" }
        #expect(ctrlTab?["source"] == "default")
        #expect(ctrlTab?["display"] == .string(Shortcut("\t", modifiers: [.control]).displayString))
        #expect(all.contains { $0["key"] == "cmd+j j" && $0["command"] == "terminal.scrollToSelection" }, "a chord reads as two strokes")

        let filtered = Self.bindings(KeybindingReports.list(["query": "ctrl+tab"], registry: registry))
        #expect(!filtered.isEmpty)
        #expect(filtered.allSatisfy { $0["key"]?.stringValue?.contains("ctrl+tab") == true })
        let byCommand = Self.bindings(KeybindingReports.list(["command": "prevSurface"], registry: registry))
        #expect(!byCommand.isEmpty)
        #expect(byCommand.allSatisfy { $0["command"] == "prevSurface" })
        #expect(Self.bindings(KeybindingReports.list(["source": "user"], registry: registry)).isEmpty)
    }

    @Test func resolveReportsTheOutcomeAndEveryCandidateVerdict() throws {
        let registry = Self.registry()
        let report = try #require(KeybindingReports.resolve("ctrl+tab", context: Self.agent, registry: registry, window: "w1"))
        #expect(report["outcome"] == "run")
        #expect(report["winner"]?["command"] == "nextSurface")
        #expect(report["window"] == "w1")
        let verdicts = (report["candidates"]?.arrayValue ?? []).compactMap { $0["verdict"]?.stringValue }
        #expect(verdicts.contains("won"))
        #expect(verdicts.contains("whenFalse"), "copy mode's Ctrl-Tab entry is listed with its verdict")
        #expect(report["context"]?["surfaceKind"] == "agent")

        registry.setKeyBindingLayers(KeyBindingLayers(user: [
            KeyBinding(keys: [Shortcut("k", modifiers: [.control]), Shortcut("x", modifiers: [])], command: "toggleSidebar", source: .user),
        ]))
        let armed = try #require(KeybindingReports.resolve("ctrl+k", context: Self.agent, registry: registry, window: nil))
        #expect(armed["outcome"] == "armed")
        #expect(armed["armed"] == "ctrl+k")
        let ran = try #require(KeybindingReports.resolve("ctrl+k x", context: Self.agent, registry: registry, window: nil))
        #expect(ran["winner"]?["source"] == "user")
        #expect(KeybindingReports.resolve("ctrl+nope", context: Self.agent, registry: registry, window: nil) == nil)
    }

    @Test func argsAndContextKeysAreJSON() {
        let registry = Self.registry()
        registry.setKeyBindingLayers(KeyBindingLayers(user: [
            KeyBinding(keys: [Shortcut("k", modifiers: [.control])], command: "terminal.setTheme",
                       arguments: ["theme": .string("Builtin Dark")], source: .user),
        ]))
        let entry = Self.bindings(KeybindingReports.list(["source": "user"], registry: registry)).first
        #expect(entry?["args"]?["theme"] == "Builtin Dark")
        let context = KeybindingReports.contextKeys(Self.agent, window: "w2")
        #expect(context["window"] == "w2")
        #expect(context["keys"]?["agentPaneFocused"] == true)
        #expect(KeybindingReports.keys(from: "ctrl+k s") == [Shortcut("k", modifiers: [.control]), Shortcut("s", modifiers: [])])
        #expect(KeybindingReports.text([Shortcut("k", modifiers: [.control]), Shortcut("s", modifiers: [])]) == "ctrl+k s")
    }
}
