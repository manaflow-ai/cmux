#if DEBUG
import CmuxMobileShellModel

@MainActor
final class HideComputersVerifierIdentityProvider: MobileIdentityProviding {
    let currentUserID: String?

    init(userID: String?) {
        currentUserID = userID
    }
}
#endif
