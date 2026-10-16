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
    public func requestIfNeeded() async -> State {
        let current = backend.state
        guard current == .notDetermined else { return current }
        if let pending { return await pending.value }
        let backend = backend
        let task = Task { @MainActor in await backend.request() }
        pending = task
        let result = await task.value
        pending = nil
        return result
    }

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
/// original. Only a decided answer (authorized or denied) unwraps both
/// methods: a call the app may not ask for (no recent input, another origin,
/// for example GitHub's conditional request on page load) leaves them wrapped,
/// so the person's later click still raises the prompt. After the first
/// decision new pages get no script at all.
///
/// Availability (passkeys.md K19): WebKit answers
/// `isUserVerifyingPlatformAuthenticatorAvailable()` false until the person
/// allows passkeys, and sites read it on page load (GitHub shows "This
/// browser or device is reporting partial passkey support"). When the app
/// carries the browser passkey entitlement, a ceremony after the person's
/// input asks once and then runs, so while the answer is undecided the
/// script reports the platform authenticator as available (also in
/// `getClientCapabilities()`). It reads the app's state each time
/// (`{kind: "state"}`, never a prompt), so a decision made in another tab
/// counts. Without the entitlement (DEV builds) it reports WebKit's own answer.
nonisolated enum WebKitPasskeyScript {
    static let messageHandlerName = "cmuxPasskeyAuthorization"

    static func source(platformAuthenticatorPending: Bool) -> String {
        body.replacingOccurrences(of: "__CMUX_PASSKEY_PENDING__", with: platformAuthenticatorPending ? "true" : "false")
    }

    private static let body = #"""
    (() => {
      const platformPending = __CMUX_PASSKEY_PENDING__;
      const credentials = navigator.credentials;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cmuxPasskeyAuthorization;
      if (!credentials || !handler || credentials.__cmuxPasskeyWrapped) return;
      const original = { create: credentials.create.bind(credentials), get: credentials.get.bind(credentials) };
      let asked = null;
      let decided = false;
      const unwrap = () => { credentials.create = original.create; credentials.get = original.get; };
      const wrap = (name) => function (options) {
        if (!options || !options.publicKey) return original[name](options);
        if (!asked) asked = handler.postMessage({ kind: name }).catch(() => 'error');
        const pending = asked;
        return pending.then((answer) => {
          if (answer === 'authorized' || answer === 'denied') { decided = true; unwrap(); }
          else if (asked === pending) asked = null;
          return original[name](options);
        });
      };
      Object.defineProperty(credentials, '__cmuxPasskeyWrapped', { value: true });
      credentials.create = wrap('create');
      credentials.get = wrap('get');
      const PKC = window.PublicKeyCredential;
      if (!platformPending || !PKC || window.top !== window) return;
      // The app's current answer, read without asking (a decision in another tab counts).
      const undecided = () => decided ? Promise.resolve(false)
        : handler.postMessage({ kind: 'state' }).then((state) => state === 'notDetermined', () => false);
      const uvpaa = PKC.isUserVerifyingPlatformAuthenticatorAvailable && PKC.isUserVerifyingPlatformAuthenticatorAvailable.bind(PKC);
      if (uvpaa) {
        PKC.isUserVerifyingPlatformAuthenticatorAvailable = function () {
          return undecided().then((pending) => pending ? true : uvpaa());
        };
      }
      const capabilities = PKC.getClientCapabilities && PKC.getClientCapabilities.bind(PKC);
      if (capabilities) {
        PKC.getClientCapabilities = function () {
          return Promise.all([capabilities(), undecided()]).then(([caps, pending]) => {
            if (!pending || !caps || typeof caps !== 'object') return caps;
            return Object.assign({}, caps, { userVerifyingPlatformAuthenticator: true, passkeyPlatformAuthenticator: true });
          });
        };
      }
    })();
    """#
}
