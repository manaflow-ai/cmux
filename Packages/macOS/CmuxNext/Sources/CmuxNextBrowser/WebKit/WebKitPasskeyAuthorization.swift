public import AuthenticationServices
import Foundation

/// Browser passkey authorization for WebKit tabs (plans/cmux-next/passkeys.md,
/// 3.3 and R141). WebKit runs WebAuthn for a browser app only after the
/// person allows it once ("Allow cmux to use passkeys"), through
/// `ASAuthorizationWebBrowserPublicKeyCredentialManager`, with the
/// `com.apple.developer.web-browser.public-key-credential` entitlement
/// (signed nightly and release; tagged DEV builds lack it). Until then
/// WebKit reports no platform authenticator, which is what made GitHub show
/// "partial passkey support". The question is asked at most once per app
/// session, lazily, on a page's first WebAuthn call after a person's input,
/// never on page load.
@MainActor
public final class WebKitPasskeyAuthorization {
    public enum State: String, Sendable {
        case authorized, denied, notDetermined
    }

    @MainActor
    public protocol Backend: AnyObject {
        var state: State { get }
        func request() async -> State
    }

    public static let shared = WebKitPasskeyAuthorization(backend: SystemBackend())

    private let backend: any Backend
    private var pending: Task<State, Never>?

    public init(backend: any Backend) {
        self.backend = backend
    }

    public var state: State { backend.state }

    /// The state after asking when it is still undetermined; concurrent
    /// callers share the one system prompt.
    public func requestIfNeeded() async -> State { backend.state }  // stub (red)

    /// AuthenticationServices.
    final class SystemBackend: Backend {
        private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()

        var state: State { Self.map(manager.authorizationStateForPlatformCredentials) }

        func request() async -> State {
            await withCheckedContinuation { continuation in
                manager.requestAuthorizationForPublicKeyCredentials { state in
                    continuation.resume(returning: Self.map(state))
                }
            }
        }

        static func map(_ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> State {
            switch state {
            case .authorized: .authorized
            case .denied: .denied
            default: .notDetermined
            }
        }
    }
}

/// Wraps `navigator.credentials.create/get` while authorization is undecided:
/// the first call with `publicKey` options waits for the app to ask the
/// person (`cmuxPasskeyAuthorization`, a reply handler), then calls the
/// original and unwraps both methods. After the first decision new pages get
/// no script at all.
nonisolated enum WebKitPasskeyScript {
    static let messageHandlerName = "cmuxPasskeyAuthorization"

    static let source = ""  // stub (red)
}
