import Testing
@testable import CmuxTerminalCore

/// Verifies the cmux-owned numbered-workspace keybind unbinds match Ghostty's
/// inline-config wire format: both the Unicode (`super+1`) and physical-key
/// (`super+digit_1`) forms for digits 1...9, newline-joined.
@Suite struct NumberedWorkspaceGhosttyUnbindsTests {
    @Test func emitsBothFormsForEveryDigit() {
        let lines = GhosttyConfigDiscovery.numberedWorkspaceGhosttyUnbinds
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // 9 digits x 2 forms (Unicode + physical-key).
        #expect(lines.count == 18)
        for digit in 1...9 {
            #expect(lines.contains("keybind = super+\(digit)=unbind"))
            #expect(lines.contains("keybind = super+digit_\(digit)=unbind"))
        }
    }

    @Test func preservesDigitOrderAndPairing() {
        let expected = (1...9).flatMap { digit in
            ["keybind = super+\(digit)=unbind", "keybind = super+digit_\(digit)=unbind"]
        }.joined(separator: "\n")
        #expect(GhosttyConfigDiscovery.numberedWorkspaceGhosttyUnbinds == expected)
    }
}
