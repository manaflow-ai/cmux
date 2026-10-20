import CmuxNextAccounts
import Foundation

// cmux's own row of Settings > Accounts, over Cloud auth: the same sign-in
// (CloudAuth.beginSignIn) and sign-out (CloudService.signOut) the palette,
// the sidebar and the Cloud page run.
extension AccountsService {
    var cmuxAccount: CmuxAccountState {
        if let showcaseMock { return showcaseMock.cmuxAccount }
        let auth = services.cloud.auth, flow = auth.browserSignIn
        if auth.isSignedIn {
            return CmuxAccountState(signedIn: true, label: CmuxAccountState.mask(auth.user?.primaryEmail) ?? auth.user?.displayName)
        }
        let failure = flow.lastFailure.map { error in
            [error.errorDescription, flow.lastFailureDetail.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        }
        return CmuxAccountState(signedIn: false, signingIn: flow.isPresentingSignIn, waitingForBrowser: flow.signInIsSlow,
                                failure: failure)
    }

    func runCmuxAccount(_ action: CmuxAccountAction) {
        if let showcaseMock { showcaseMock.runCmuxAccount(action); model.refresh(); return }
        let cloud = services.cloud
        switch action {
        case .signIn, .switchAccount:
            let attempt = cloud.auth.beginSignIn(selectAccount: action == .switchAccount)
            // task-owner: one hosted sign-in; ends when the browser flow returns
            Task { [weak self] in
                if await attempt.value { self?.model.refresh() }
            }
        case .cancelSignIn:
            cloud.auth.cancelSignIn()
        case .continueInBrowser:
            if !cloud.auth.continueSignInInBrowser() { logger.info("no cmux sign-in in progress to open in the browser") }
        case .signOut:
            // task-owner: one sign-out; the row follows Cloud auth's state
            Task { [weak self] in
                await cloud.signOut()
                self?.model.refresh()
            }
        }
    }
}
