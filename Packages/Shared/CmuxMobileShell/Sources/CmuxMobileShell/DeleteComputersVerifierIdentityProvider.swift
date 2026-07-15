#if DEBUG
import CmuxMobileShellModel

@MainActor
final class DeleteComputersVerifierIdentityProvider: MobileIdentityProviding {
    let currentUserID: String?

    init(userID: String?) {
        currentUserID = userID
    }
}
#endif
