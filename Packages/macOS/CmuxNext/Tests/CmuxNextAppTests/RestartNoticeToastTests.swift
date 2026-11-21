import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// "cmux restarted after a problem" is a shared toast (Lawrence 2026-11-13: every toast and prompt takes
/// the style picked in the Toast Playground): Report and Show Crash Log are its two actions, it waits for
/// an answer, and it draws no window of its own.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct RestartNoticeToastTests {
    @Test func theRestartNoticeShowsThroughTheSharedCenter() throws {
        let center = CmuxToastCenter(clock: ContinuousClock())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        var ran: [String] = []
        _ = CrashRecoveryService.presentRestartNotice(text: "cmux restarted after a problem", on: window, center: center,
                                                       onShowLog: { ran.append("log") }, onReport: { ran.append("report") })
        let toast = try #require(center.toasts(in: window).first)
        #expect(toast.message == "cmux restarted after a problem")
        #expect(toast.action?.title == CrashStrings.report)
        #expect(toast.secondaryAction?.title == CrashStrings.showLog)
        #expect(toast.duration == CmuxToast.untilClosed)
        #expect(window.childWindows?.isEmpty ?? true, "the notice drew a panel of its own")
        #expect(center.runSecondaryAction(id: toast.id, in: window))
        #expect(ran == ["log"])
    }
}
