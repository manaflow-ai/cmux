public import AuthenticationServices

extension ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
    /// The platform passkey availability this authorization state should advertise to the page,
    /// given whether the device is configured for passkeys and whether the caller may prompt for
    /// platform authorization. `nil` means availability is unknown and should not be advertised.
    public func browserAdvertisedPlatformPasskeyAvailability(
        deviceConfiguredForPasskeys: Bool?,
        callerMayPromptForPlatformAuthorization: Bool
    ) -> Bool? {
        if self == .denied {
            return false
        }

        if self == .notDetermined && !callerMayPromptForPlatformAuthorization {
            return false
        }

        return deviceConfiguredForPasskeys
    }
}
