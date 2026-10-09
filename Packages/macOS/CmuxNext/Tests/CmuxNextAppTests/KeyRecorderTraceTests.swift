import AppKit
import CmuxNextDesign
@testable import CmuxNextApp
import Testing

/// nxdog49: debug.key reported action "closeTab" for a stroke the Keyboard
/// Shortcuts recorder took (a stale value). The trace says the recorder took
/// the key, and no action is reported for it.
@MainActor
struct KeyRecorderTraceTests {
    @Test func aRecorderStrokeIsTracedAsTheRecorders() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let router = try #require(services.keyRouter)
        var lines: [String] = []
        router.trace = { lines.append($0) }
        router.keyRecorder = { _, _ in true }
        #expect(router.interceptKeyDown(try KeyInterceptionTests.key("w", keyCode: 13, [.command]), in: nil))
        #expect(lines.contains("recorder: the Keyboard Shortcuts recorder took the key"))
        #expect(router.lastInterception == nil)
    }
}

/// nxdog52: debug.key reported closeTab / closeOtherTabsInPane for the Cmd-Z
/// that ran the undo toast (the previous action, stale). The toast's run is
/// traced as the toast's, and no action is reported for it.
@MainActor
struct UndoToastTraceTests {
    @Test func commandZOnAnUndoToastIsTracedAsTheToasts() throws {
        let router = KeyOwnershipMatrixTests.services().keyRouter
        let toasts = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        router.undoToasts = toasts
        let window = ToastUndoKeyTests.window()
        var ran = 0
        toasts.show(CmuxToast(id: "closed", message: "Closed", action: .undo(), duration: .seconds(5)), in: window).onAction = { ran += 1 }
        var lines: [String] = []
        router.trace = { lines.append($0) }
        #expect(router.interceptKeyDown(ToastUndoKeyTests.key(window, "z", 6, .command), in: window))
        #expect(ran == 1)
        #expect(lines.contains("undo toast: Cmd-Z ran the toast"))
        #expect(router.lastInterception == nil)
    }
}
