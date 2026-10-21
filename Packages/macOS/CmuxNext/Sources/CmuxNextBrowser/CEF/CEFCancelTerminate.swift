import AppKit

/// Chromium's application class (`BrowserCrApplication`) answers
/// `-cancelTerminate:`, and Chromium sends it to NSApp when a person stays on
/// a page in its own beforeunload dialog
/// (`chrome_browser_application_mac::CancelTerminate`, from
/// `JavaScriptAppModalDialogCocoa::OnAlertFinished`). cmux's NSApplication
/// did not answer it: the send raised an unrecognized-selector exception on
/// the main thread (nightly 1.0.0-nightly.3950982952501, 2026-10-20). The
/// shim now asks every beforeunload in the tab itself (`CEFTab+UserClose`),
/// so Chromium's dialog should not show; this keeps any other path safe.
/// cmux's quit never waits on Chromium's terminate, so there is nothing to cancel.
extension NSApplication {
    @objc(cancelTerminate:)
    func chromiumCancelTerminate(_ sender: Any?) {}
}
