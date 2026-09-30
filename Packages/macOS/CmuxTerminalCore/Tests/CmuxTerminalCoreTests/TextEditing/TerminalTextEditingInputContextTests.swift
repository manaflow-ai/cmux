import CmuxTerminalCore
import Testing

@Suite("Shell-owned terminal text editing")
struct TerminalTextEditingInputContextTests {
    private func prompt() -> TerminalTextEditingInputContext {
        var context = TerminalTextEditingInputContext()
        context.reportPrompt(isSupportedShellPrompt: true, foregroundProcessID: 42, runtimeGeneration: 7)
        return context
    }

    @Test func supportedPromptAllowsOptedInGestures() {
        #expect(prompt().allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 7))
        #expect(!prompt().allowsGestures(enabled: false, foregroundProcessID: 42, runtimeGeneration: 7))
    }

    @Test func unknownContextPassesKeysThrough() {
        #expect(!TerminalTextEditingInputContext().allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 7))
    }

    @Test func foregroundProgramWinsEvenBeforeShellReportArrives() {
        #expect(!prompt().allowsGestures(enabled: true, foregroundProcessID: 99, runtimeGeneration: 7))
        #expect(!prompt().allowsGestures(enabled: true, foregroundProcessID: nil, runtimeGeneration: 7))
    }

    @Test func submittingImmediatelyPausesUntilNextPrompt() {
        var context = prompt()
        context.commandWasSubmitted()
        #expect(!context.allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 7))
        context.reportPrompt(isSupportedShellPrompt: true, foregroundProcessID: 42, runtimeGeneration: 7)
        #expect(context.allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 7))
    }

    @Test func runningOrUnsupportedShellWithdrawsPrompt() {
        var context = prompt()
        context.reportPrompt(isSupportedShellPrompt: false, foregroundProcessID: 42, runtimeGeneration: 7)
        #expect(!context.allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 7))
    }

    @Test func replacedRuntimeCannotInheritOldPrompt() {
        #expect(!prompt().allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 8))
    }

    @Test func copyModeAndIMECompositionKeepTheirKeys() {
        #expect(!prompt().allowsGestures(enabled: true, foregroundProcessID: 42, runtimeGeneration: 7, anotherInputModeOwnsKeys: true))
    }

    @Test func zeroProcessIdentityNeverEnablesEditing() {
        var context = TerminalTextEditingInputContext()
        context.reportPrompt(isSupportedShellPrompt: true, foregroundProcessID: 0, runtimeGeneration: 7)
        #expect(!context.allowsGestures(enabled: true, foregroundProcessID: 0, runtimeGeneration: 7))
    }
}
