import Foundation

/// A page's alert, confirm, prompt and HTTP authentication in cmux's own dialogs over its tab (feature
/// `chromiumPageDialogs`; JS_DIALOG and AUTH from CEFShim/src/shim_client.mm, task p01-process-063), where
/// Chrome asks in a tab-modal dialog (`TabModalDialogManager`,
/// components/javascript_dialogs/tab_modal_dialog_manager.cc) and in its login dialog (`LoginHandler`,
/// chrome/browser/ui/login/login_handler.cc). One path in process and in the Chromium Host, whose page
/// windows never show a widget. Each question joins the tab's prompt list, which `BrowserPromptDialogs`
/// shows as a `CmuxDialogSpec`: a tab in the background asks when it is shown, a closed tab answers at once
/// (`BrowserPrompt.dismissalResponse`), and a question with no tab is cancelled, so no page waits on nobody.
struct CEFPageDialogs {
    let runtime: CEFRuntime

    func handle(_ event: CEFShimEvent) {
        switch event {
        case .jsDialog(let browser, let token, let dialog):
            if let tab = runtime.tabsByBrowser[browser] { ask(dialog, token: token, in: tab) } else { answer(token, .cancel) }
        case .auth(let browser, let token, let challenge):
            if let tab = runtime.tabsByBrowser[browser] { signIn(challenge, token: token, in: tab) } else { answer(token, credential: nil) }
        case .jsDialogsDismissed(let browser):
            // The shim forgot the tokens: each question goes, and its answer finds nothing.
            for prompt in runtime.tabsByBrowser[browser]?.pendingPrompts ?? [] where prompt.kind.isJavaScriptDialog {
                prompt.respond(.cancel)
            }
        case .authDismissed(let browser):
            for prompt in runtime.tabsByBrowser[browser]?.pendingPrompts ?? [] where prompt.kind.isSignIn {
                prompt.respond(.cancel)
            }
        default:
            break
        }
    }

    private func ask(_ dialog: CEFJSDialog, token: Int32, in tab: CEFTab) {
        let dialogs = self
        tab.enqueuePrompt(dialog.promptKind, origin: dialog.displayOrigin) { response in dialogs.answer(token, response) }
    }

    private func answer(_ token: Int32, _ response: BrowserPromptResponse) {
        let reply = CEFJSDialog.answer(to: response)
        _ = runtime.shim?.jsDialogReply(token, reply.accept ? 1 : 0, reply.text)
    }

    /// The WebKit tab's sign-in (`BrowserHTTPSignIn`): a login remembered for the server answers the first
    /// try, else the tab asks. A second ask for the same server and realm before the page commits means the
    /// last answer failed (WebKit's `previousFailureCount`); after ``BrowserHTTPAuth/attemptLimit`` the
    /// request is cancelled and the server's own page loads.
    private func signIn(_ challenge: CEFAuthChallenge, token: Int32, in tab: CEFTab) {
        let space = challenge.protectionSpace
        let key = BrowserHTTPCredentialKey(profile: tab.profileID, space: space)
        let failures = tab.signInAttempts[key, default: 0]
        guard failures < BrowserHTTPAuth.attemptLimit else { return answer(token, credential: nil) }
        let dialogs = self, stores = runtime.stores
        let memory = BrowserHTTPSignInMemory(store: stores.httpCredentials, offTheRecord: stores.offTheRecord.isOffTheRecord(tab.profileID))
        BrowserHTTPSignIn(memory: memory, key: key, failures: failures, space: space) { [weak tab] kind, origin, done in
            guard let tab else { return done(.cancel) }
            tab.enqueuePrompt(kind, origin: origin, completion: done)
        }.run { [weak tab] _, credential in
            if credential != nil { tab?.signInAttempts[key, default: 0] += 1 }
            dialogs.answer(token, credential: credential)
        }
    }

    private func answer(_ token: Int32, credential: URLCredential?) {
        guard let credential else {
            _ = runtime.shim?.authReply(token, 0, nil, nil)
            return
        }
        _ = runtime.shim?.authReply(token, 1, credential.user ?? "", credential.password ?? "")
    }
}
