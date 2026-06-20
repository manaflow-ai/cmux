import Testing

@testable import CmuxCommandPalette

@Suite("CommandPaletteCommandRunPlan")
struct CommandPaletteCommandRunPlanTests {
    @Test("non-dismissing command runs only its action")
    func nonDismissing() {
        #expect(
            CommandPaletteCommandRunPlan(
                dismissOnRun: false,
                dismissBeforeRun: true,
                hasFocusTarget: true
            ).steps == [.run]
        )
        #expect(
            CommandPaletteCommandRunPlan(
                dismissOnRun: false,
                dismissBeforeRun: false,
                hasFocusTarget: false
            ).steps == [.run]
        )
    }

    @Test("dismiss-before-run runs dismiss then action")
    func dismissBeforeRun() {
        #expect(
            CommandPaletteCommandRunPlan(
                dismissOnRun: true,
                dismissBeforeRun: true,
                hasFocusTarget: true
            ).steps == [.dismiss(restoreFocus: true), .run]
        )
        #expect(
            CommandPaletteCommandRunPlan(
                dismissOnRun: true,
                dismissBeforeRun: true,
                hasFocusTarget: false
            ).steps == [.dismiss(restoreFocus: false), .run]
        )
    }

    @Test("default dismissing command runs action then dismiss")
    func dismissAfterRun() {
        #expect(
            CommandPaletteCommandRunPlan(
                dismissOnRun: true,
                dismissBeforeRun: false,
                hasFocusTarget: true
            ).steps == [.run, .dismiss(restoreFocus: true)]
        )
        #expect(
            CommandPaletteCommandRunPlan(
                dismissOnRun: true,
                dismissBeforeRun: false,
                hasFocusTarget: false
            ).steps == [.run, .dismiss(restoreFocus: false)]
        )
    }
}
