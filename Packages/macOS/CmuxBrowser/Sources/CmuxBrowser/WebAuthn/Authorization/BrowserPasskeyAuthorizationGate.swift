public import AuthenticationServices

/// Coalesces platform passkey authorization for the browser's WebAuthn bridge.
///
/// Wraps `ASAuthorizationWebBrowserPublicKeyCredentialManager`, exposing the current
/// platform-credential authorization state and a request that is deduplicated while a
/// prompt is already in flight, so concurrent WebAuthn ceremonies share one prompt.
@MainActor
public final class BrowserPasskeyAuthorizationGate {
    public static let shared = BrowserPasskeyAuthorizationGate()

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var inFlightRequest: Task<ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState, Never>?

    /// The current platform-credential authorization state, read without prompting.
    public func currentAuthorizationState() -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        manager.authorizationStateForPlatformCredentials
    }

    /// Requests platform-credential authorization when it is still undetermined, coalescing
    /// concurrent callers onto a single in-flight prompt and returning the resolved state.
    public func authorizeIfNeeded() async -> ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        let currentState = manager.authorizationStateForPlatformCredentials
        guard currentState == .notDetermined else { return currentState }

        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task { @MainActor [manager] in
            await withCheckedContinuation { continuation in
                manager.requestAuthorizationForPublicKeyCredentials { authorizationState in
                    continuation.resume(returning: authorizationState)
                }
            }
        }

        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }
}
