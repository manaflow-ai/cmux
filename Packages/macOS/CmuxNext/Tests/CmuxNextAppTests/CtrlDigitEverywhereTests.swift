import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// R85 (Lawrence): Ctrl-1...9 select tab N in every surface (the VS Code
/// default; Spaces moved to Ctrl-Opt-1...9, Lawrence 2026-10-04). The R59
/// dispatcher resolves them before any surface (terminal, WebKit or Chromium
/// page, agent pane, React page, Home, sidebar, text fields) gets the key.
/// Browser focus mode keeps every key by design; a panel (palette) has its
/// own keys.
@MainActor
struct CtrlDigitEverywhereTests {
    typealias M = KeyOwnershipMatrixTests
    typealias K = KeyInterceptionTests

    static let keyCodes: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]

    @Test func controlDigitsRunTheirActionInEverySurface() throws {
        let services = M.services()
        let router = services.keyRouter!
        var failures: [String] = []
        for surface in M.surfaces where !["browser focus mode", "palette open"].contains(surface.name) {
            for digit in "123456789" {
                let event = try K.key(String(digit), keyCode: Self.keyCodes[digit]!, [.control])
                let facts = KeyRouter.Facts(terminalCopyMode: surface.facts.terminalCopyMode)
                let decision = router.decide(event, focus: surface.focus, keyWindow: surface.window, facts: facts)
                guard case .run(let candidate) = decision, candidate.id == "selectSurfaceByNumber",
                      candidate.source == .registry(argument: String(digit)) else {
                    failures.append("\(surface.name) ctrl+\(digit): \(decision)")
                    continue
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Spaces keep a digit family: Ctrl-Opt-1...9.
    @Test func spacesMoveToControlOptionDigits() throws {
        let registry = M.services().registry
        #expect(registry.descriptor(for: "selectSurfaceByNumber")?.defaultShortcut == Shortcut("1", modifiers: [.control]))
        #expect(registry.descriptor(for: "space.selectByNumber")?.defaultShortcut == Shortcut("1", modifiers: [.control, .option]))
    }
}

import CmuxNextSettings

extension CtrlDigitEverywhereTests {
    /// The onboarding choice "Ctrl-digits select Spaces" swaps the two
    /// families; the default scheme writes nothing.
    @Test func theSpacesSchemeSwapsTheDigitFamilies() throws {
        #expect(ShortcutDigitScheme.tabs.overrides.isEmpty)
        let registry = M.services().registry
        for (id, value) in ShortcutDigitScheme.spaces.overrides {
            guard case .stroke(let stroke)? = ShortcutBindingFormat.parse(value) else { Issue.record("\(id)"); continue }
            registry.setShortcutOverride(SettingsApplier.shortcut(for: stroke), for: ActionID(rawValue: id))
        }
        #expect(registry.effectiveShortcut(for: "space.selectByNumber") == Shortcut("1", modifiers: [.control]))
        #expect(registry.effectiveShortcut(for: "selectSurfaceByNumber") == Shortcut("1", modifiers: [.control, .option]))
    }
}
