import AppKit
import Carbon.HIToolbox
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `tabs.commandDigits` (Settings > Keyboard > Command-1 to 9 Select): `workspaces`, the default,
/// keeps Cmd-1…9 on the sidebar and Ctrl-1…9 on tabs; `tabs` trades the two keys. A binding the
/// user set for either action wins, and then neither moves.
@MainActor @Suite(.serialized) struct CommandDigitsSettingTests {
    private static let command = Shortcut("1", modifiers: [.command])
    private static let control = Shortcut("1", modifiers: [.control])

    private static func snapshot(_ tabs: [String: JSONValue], bindings: [String: JSONValue] = [:]) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = ["tabs": .object(tabs)]
        if !bindings.isEmpty { root["shortcuts"] = .object(["bindings": .object(bindings)]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    /// An applier on a registry where every catalog action is bound, as in the app.
    private static func applier() -> SettingsApplier {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return SettingsApplier(design: DesignSettings(), registry: registry)
    }

    /// The action and digit Cmd-`digit` or Ctrl-`digit` runs with `context` focused.
    private static func resolve(_ registry: ActionRegistry, _ modifiers: NSEvent.ModifierFlags, digit: Int = 3,
                                in context: ActionContext = []) throws -> String? {
        registry.context = context
        let character = String(digit)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(kVK_ANSI_3)
        ))
        return registry.resolveShortcut(for: event).map { "\($0.id.rawValue) \($0.argument ?? "")" }
    }

    @Test func workspacesKeepCommandDigitsByDefault() throws {
        let parsed = Self.snapshot([:])
        #expect(parsed.commandDigits == .workspaces)
        let applier = Self.applier()
        applier.apply(parsed)
        let registry = applier.registry
        #expect(registry.effectiveShortcut(for: "selectWorkspaceByNumber") == Self.command)
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Self.control)
        #expect(try Self.resolve(registry, [.command]) == "selectWorkspaceByNumber 3")
    }

    @Test(arguments: [ActionContext(), .terminalFocused, .browserFocused])
    func tabsTradeTheTwoKeys(_ context: ActionContext) throws {
        let applier = Self.applier()
        applier.apply(Self.snapshot(["commandDigits": .string("tabs")]))
        let registry = applier.registry
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Self.command)
        #expect(registry.effectiveShortcut(for: "selectWorkspaceByNumber") == Self.control)
        #expect(try Self.resolve(registry, [.command], in: context) == "selectSurfaceByNumber 3")
        #expect(try Self.resolve(registry, [.control], in: context) == "selectWorkspaceByNumber 3")
    }

    @Test func aBindingTheUserSetForEitherActionKeepsBothWhereTheyAre() {
        let applier = Self.applier()
        applier.apply(Self.snapshot(["commandDigits": .string("tabs")], bindings: ["selectWorkspaceByNumber": .string("cmd+opt+1")]))
        let registry = applier.registry
        #expect(registry.effectiveShortcut(for: "selectWorkspaceByNumber") == Shortcut("1", modifiers: [.command, .option]))
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Self.control)
    }

    @Test func turningItBackToWorkspacesRestoresTheDefaults() throws {
        let applier = Self.applier()
        applier.apply(Self.snapshot(["commandDigits": .string("tabs")]))
        applier.apply(Self.snapshot([:]))
        let registry = applier.registry
        #expect(registry.effectiveShortcut(for: "selectWorkspaceByNumber") == Self.command)
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Self.control)
        #expect(try Self.resolve(registry, [.command]) == "selectWorkspaceByNumber 3")
    }

    @Test func aBadValueIsWorkspacesPlusADiagnostic() {
        let parsed = Self.snapshot(["commandDigits": .string("panes")])
        #expect(parsed.commandDigits == .workspaces)
        #expect(parsed.diagnostics.contains { $0.path == "tabs.commandDigits" })
    }

    @Test func settingsShowsTheRowInSidebarNavigation() {
        let keys = SettingsPageLayout.specs.first { $0.id == "keyboard" }?.groups.flatMap(\.keys) ?? []
        #expect(keys.first == "tabs.commandDigits")
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.commandDigits"))
    }
}
