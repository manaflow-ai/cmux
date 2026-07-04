import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("CustomToolbarAction macro payload")
struct CustomToolbarActionMacroTests {
    @Test("macro concatenates its steps' bytes in order")
    func concatenatesInOrder() {
        let action = CustomToolbarAction(
            title: "Plan + run",
            payload: .macro([
                .keyCombo(modifiers: [.shift], key: .tab), // ESC [ Z
                .text("go\n"),                              // "go\r"
            ])
        )
        #expect(action.output == Data([0x1B, 0x5B, 0x5A]) + Data("go\r".utf8))
    }

    @Test("rotate-permission-mode example: a single ⇧Tab step sends ESC[Z")
    func rotatePermissionModeExample() {
        // The issue's motivating example: one button that rotates an agent's
        // permission mode is a single Shift+Tab.
        let action = CustomToolbarAction(
            title: "Mode",
            payload: .macro([.keyCombo(modifiers: [.shift], key: .tab)])
        )
        #expect(action.output == Data([0x1B, 0x5B, 0x5A]))
    }

    @Test("macro skips steps that resolve to nothing")
    func skipsEmptySteps() {
        let action = CustomToolbarAction(
            title: "x",
            payload: .macro([
                .text(""),                                       // skipped
                .keyCombo(modifiers: [.control], key: .upArrow), // unencodable, skipped
                .text("ok"),                                     // "ok"
            ])
        )
        #expect(action.output == Data("ok".utf8))
    }

    @Test("a macro whose every step resolves to nothing produces no output")
    func allEmptyMacroIsNil() {
        let action = CustomToolbarAction(
            title: "x",
            payload: .macro([.text(""), .keyCombo(modifiers: [.control], key: .upArrow)])
        )
        #expect(action.output == nil)
        #expect(CustomToolbarAction(title: "x", payload: .macro([])).output == nil)
    }

    @Test("Codable round-trips a macro payload")
    func codableMacro() throws {
        let action = CustomToolbarAction(
            title: "Macro",
            payload: .macro([
                .keyCombo(modifiers: [.shift], key: .tab),
                .text("/effort high\n"),
            ])
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(CustomToolbarAction.self, from: data)
        #expect(decoded == action)
        #expect(decoded.output == action.output)
    }
}
