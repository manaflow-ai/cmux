import CmuxMobileShellModel

@MainActor
final class WorkspaceMacSelectionIdentityProvider: MobileIdentityProviding {
    var currentUserID: String?

    init(userID: String?) {
        self.currentUserID = userID
    }
}
