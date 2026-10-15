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
/// asks first; Send repeats it with the POST allowed once. A form the person
/// submits (`.formSubmitted`) goes through, except as the first navigation
/// of a restore. Which entries came from a POST is part of the tab's saved
/// session (`BrowserSavedEntry.formPost`, kept by the daemon), fed by each
/// main-frame commit.
struct WebKitFormResubmission {
    /// What Send repeats.
    enum Retry {
        /// The restored history, applied again.
        case restore(Data)
        case reload
        /// The back/forward entry at this address.
        case entry(URL)
    }

    /// A saved history is being restored: its first main-frame navigation
    /// is the restore's own.
    var restoring = false
    /// The history being restored, for Send.
    var restoreData: Data?
    /// The person chose Send: the next main-frame navigation may POST.
    var allowOnce = false
    /// The main-frame request allowed last was a POST (until it commits).
    var pendingPost = false

    /// Decides a main-frame navigation; true when it must be cancelled and
    /// asked about. Every main-frame decision ends a restore's window and
    /// uses up a Send.
    mutating func shouldAsk(method: String?, type: WKNavigationType) -> Bool {
        let post = method?.uppercased() == "POST"
        let wasRestoring = restoring, allowed = allowOnce
        restoring = false
        allowOnce = false
        let ask = post && !allowed && (wasRestoring || type == .formResubmitted)
        pendingPost = post && !ask
        return ask
    }
}

extension WebKitTab {
    /// The navigation delegate's check for a navigation in this tab; true
    /// when it was cancelled (the tab then asks the person).
    func cancelsFormResubmission(_ action: WKNavigationAction, decisionHandler: () -> Void) -> Bool {
        // A request for another window (`target=_blank`) is not this tab's.
        guard action.targetFrame?.isMainFrame == true else { return false }
        let restoreData = formResubmission.restoring ? formResubmission.restoreData : nil
        guard formResubmission.shouldAsk(method: action.request.httpMethod, type: action.navigationType) else { return false }
        decisionHandler()
        let retry: WebKitFormResubmission.Retry
        if let restoreData {
            retry = .restore(restoreData)
        } else if let url = action.request.url, url != webView.backForwardList.currentItem?.url {
            retry = .entry(url)
        } else {
            retry = .reload
        }
        let message = String(localized: "browser.formResubmission.message",
                             defaultValue: "This page is the result of a form. Send the form again?", bundle: .module)
        enqueuePrompt(.confirm(message: message), origin: action.request.url.flatMap(PageInfoSite.origin(of:)) ?? "") { [weak self] response in
            guard let self, response == .accept else { return }
            resendForm(retry)
        }
        return true
    }

    /// Send: repeats the cancelled navigation with one POST allowed.
    private func resendForm(_ retry: WebKitFormResubmission.Retry) {
        formResubmission.allowOnce = true
        switch retry {
        case .restore(let data):
            webView.interactionState = data
        case .reload:
            webView.reload()
        case .entry(let url):
            let list = webView.backForwardList
            if let item = list.backList.last(where: { $0.url == url }) ?? list.forwardList.first(where: { $0.url == url }) {
                webView.go(to: item)
            } else {
                formResubmission.allowOnce = false
            }
        }
    }

    /// A main-frame document committed: the saved session learns whether it
    /// came from a POST.
    func formResubmissionCommitted() {
        formResubmission.restoring = false
        formResubmission.restoreData = nil
        restored.documentCommitted(url: webView.url, formPost: formResubmission.pendingPost)
        formResubmission.pendingPost = false
    }

    /// The main-frame navigation did not commit.
    func formResubmissionFailed() {
        formResubmission.pendingPost = false
    }
}
