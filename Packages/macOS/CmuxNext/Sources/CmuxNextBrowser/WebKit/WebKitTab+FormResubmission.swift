import Foundation
import WebKit

/// A form is never sent again without the person (BR-R1,
/// plans/cmux-next/browser-host.md decision 10).
///
/// Restoring a saved history (a wake from hibernation, Duplicate Tab,
/// Reopen Closed Tab) loads its current entry; when that entry came from a
/// POST, WebKit sends the form again with no question (`.backForward` or
/// `.formResubmitted` with method POST). Reload and Back to such a page do
/// the same (`.formResubmitted`). Each of those is cancelled and the tab
/// asks first; Send loads it again with the POST allowed once. A form the
/// person submits (`.formSubmitted`) always goes through. Which entries came
/// from a POST is part of the tab's saved session (`BrowserSavedEntry.formPost`,
/// kept by the daemon), fed by `documentCommitted(url:formPost:)`.
struct WebKitFormResubmission {
    /// A saved history is being restored, until its first commit: any POST
    /// that is not a new form submission is the restore's own.
    var restoring = false
    /// The person chose Send: the next resubmission goes through.
    var allowOnce = false
    /// The main-frame request allowed last was a POST (until it commits).
    var pendingPost = false

    /// True when a main-frame navigation must be cancelled and asked about.
    mutating func shouldAsk(method: String?, type: WKNavigationType) -> Bool {
        guard method?.uppercased() == "POST", type != .formSubmitted, restoring || type == .formResubmitted else { return false }
        if allowOnce {
            allowOnce = false
            return false
        }
        return true
    }
}

extension WebKitTab {
    /// The navigation delegate's check for a main-frame request; true when it
    /// was cancelled (the tab then asks the person).
    func cancelsFormResubmission(_ action: WKNavigationAction, decisionHandler: () -> Void) -> Bool {
        guard action.targetFrame?.isMainFrame ?? true else { return false }
        guard formResubmission.shouldAsk(method: action.request.httpMethod, type: action.navigationType) else {
            formResubmission.pendingPost = action.request.httpMethod?.uppercased() == "POST"
            return false
        }
        decisionHandler()
        formResubmission.restoring = false
        formResubmission.pendingPost = false
        let message = String(localized: "browser.formResubmission.message",
                             defaultValue: "This page is the result of a form. Send the form again?", bundle: .module)
        enqueuePrompt(.confirm(message: message), origin: action.request.url.flatMap(PageInfoSite.origin(of:)) ?? "") { [weak self] response in
            guard let self, response == .accept else { return }
            formResubmission.allowOnce = true
            webView.reload()
        }
        return true
    }

    /// A main-frame document committed: the saved session learns whether it
    /// came from a POST.
    func formResubmissionCommitted() {
        formResubmission.restoring = false
        restored.documentCommitted(url: webView.url, formPost: formResubmission.pendingPost)
        formResubmission.pendingPost = false
    }

    /// The main-frame navigation did not commit.
    func formResubmissionFailed() {
        formResubmission.restoring = false
        formResubmission.pendingPost = false
    }
}
