import Testing
@testable import CmuxTerminalCore

@Suite("Terminal compose mode")
struct TerminalComposeModePolicyTests {
    private let policy = TerminalComposeModePolicy()

    @Test("enabling compose mode activates the composer when it is not already owned")
    func enablingActivatesComposer() {
        #expect(
            policy.transition(
                isEnabled: true,
                ownsTextBox: false,
                isTextBoxActive: false
            ) == .activate
        )
    }

    @Test("disabling compose mode releases a composer it activated")
    func disablingReleasesOwnedComposer() {
        #expect(
            policy.transition(
                isEnabled: false,
                ownsTextBox: true,
                isTextBoxActive: true
            ) == .deactivate
        )
    }

    @Test("manual TextBox use is preserved when compose mode is disabled")
    func disablingPreservesManualComposer() {
        #expect(
            policy.transition(
                isEnabled: false,
                ownsTextBox: false,
                isTextBoxActive: true
            ) == .unchanged
        )
    }

    @Test("reapplying compose mode is idempotent")
    func reapplyingIsIdempotent() {
        #expect(
            policy.transition(
                isEnabled: true,
                ownsTextBox: true,
                isTextBoxActive: true
            ) == .unchanged
        )
    }

    @Test("enabling compose mode does not take over a manual composer")
    func enablingPreservesManualComposer() {
        #expect(
            policy.transition(
                isEnabled: true,
                ownsTextBox: false,
                isTextBoxActive: true
            ) == .unchanged
        )
    }
}
