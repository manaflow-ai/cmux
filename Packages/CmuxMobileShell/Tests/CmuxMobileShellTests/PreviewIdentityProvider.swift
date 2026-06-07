import CmuxMobileShellModel
@testable import CmuxMobileShell

struct PreviewIdentityProvider: MobileIdentityProviding {
    let userID: String?

    @MainActor var currentUserID: String? {
        userID
    }
}
