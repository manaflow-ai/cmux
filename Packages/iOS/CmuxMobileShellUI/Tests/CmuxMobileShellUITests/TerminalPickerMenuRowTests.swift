import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

@Suite struct TerminalPickerMenuRowTests {
    @Test func nameOnlyChangesKeepMenuRowsEqual() {
        let first = [
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-a", name: "Build")),
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-b", name: "Agent")),
        ]
        let renamed = [
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-a", name: "Build - zsh")),
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-b", name: "Agent - claude")),
        ]

        #expect(first == renamed)
    }

    @Test func structuralTerminalChangesKeepMenuRowsDifferent() {
        let first = [
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-a", name: "Build")),
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-b", name: "Agent")),
        ]
        let inserted = [
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-a", name: "Build")),
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-c", name: "TUI")),
            TerminalPickerMenuRow(MobileTerminalPreview(id: "terminal-b", name: "Agent")),
        ]

        #expect(first != inserted)
    }
}
