import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Testing

/// `app.shortcutLayout` reaches the native shortcut matcher: Keep QWERTY Positions turns on
/// ``ActionRegistry/matchesQwertyPositions``, so Cmd at the Dvorak key that types j (QWERTY C) is Cmd-C.
@MainActor @Suite(.serialized) struct ShortcutLayoutApplyTests {
    private static func snapshot(_ layout: String?) -> CmuxConfigSnapshot {
        let app: [String: JSONValue] = layout.map { ["shortcutLayout": .string($0)] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["app": .object(app)]), validDensities: [], validMetrics: [])
    }

    private static func dvorakC() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j",
                                      isARepeat: false, keyCode: 8))
    }

    @Test func followLayoutByDefault() throws {
        let registry = ActionRegistry()
        _ = SettingsApplier(design: DesignSettings(), registry: registry).apply(Self.snapshot(nil))
        #expect(!registry.matchesQwertyPositions)
        #expect(registry.shortcuts(for: try Self.dvorakC()).first == Shortcut("j", modifiers: [.command]))
    }

    @Test func qwertyPositionsReachTheRegistryAndBack() throws {
        let registry = ActionRegistry()
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        _ = applier.apply(Self.snapshot("qwertyPositions"))
        #expect(registry.matchesQwertyPositions)
        #expect(registry.shortcuts(for: try Self.dvorakC()) == [Shortcut("c", modifiers: [.command])])
        _ = applier.apply(Self.snapshot("followLayout"))
        #expect(!registry.matchesQwertyPositions)
    }
}
