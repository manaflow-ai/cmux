import CmuxMobileShellModel

/// Supplies one stable signed-in account scope to preview and package-test shells.
@MainActor
struct MobileShellPreviewIdentityProvider: MobileIdentityProviding {
    let currentUserID: String? = "cmux-mobile-shell-preview-user"
}
