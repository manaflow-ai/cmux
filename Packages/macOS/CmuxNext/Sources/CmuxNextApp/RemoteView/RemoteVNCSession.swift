import AppKit
import CmuxNextRemoteView
import CmuxVNC
import CmuxVNCDemoServer

#if DEBUG
/// The VNC side of a `remote_view` tab whose record says `via=vnc`: the
/// source, the saved sign-in, the sign-in prompt, and, for the host `mock`,
/// an in-process loopback demo server (the VNC test desktop).
@MainActor
final class RemoteVNCSession {
    let record: RemoteViewTabRecord
    let source = RemoteVNCSource()
    /// The record's address; the Keychain key for its sign-in.
    let endpoint: VNCEndpoint
    private let store = RemoteVNCCredentialStore()
    private var demo: VNCDemoServer?
    private var demoPort: UInt16?
    private var demoStart: Task<Void, Never>?
    private var prompting = false
    private var closed = false

    init(record: RemoteViewTabRecord, port: UInt16) {
        self.record = record
        // The reserved names (RemoteViewTabPolicy) are never resolved: `local` and
        // `localhost` are this Mac, `mock` is the loopback demo desktop.
        let host = record.host.lowercased()
        endpoint = VNCEndpoint(host: ["local", "localhost"].contains(host) ? "127.0.0.1" : record.host, port: port)
        if host == RemoteViewPageSession.mockHost { demo = VNCDemoServer() }
    }

    isolated deinit {
        demoStart?.cancel()
        demo?.stop()
    }

    /// Connects with the saved sign-in (or none; the host may not need one).
    func connect() {
        guard !closed else { return }
        guard let demo else {
            source.connect(to: endpoint, credentials: store.credentials(for: endpoint) ?? VNCCredentials())
            return
        }
        if let demoPort {
            source.connect(to: VNCEndpoint(host: "127.0.0.1", port: demoPort), credentials: VNCCredentials())
            return
        }
        guard demoStart == nil else { return }
        demoStart = Task { [weak self] in
            let port = try? await demo.start()
            // Closed (or gone) while the server started: stop it, never connect.
            guard let self, !closed, !Task.isCancelled else {
                demo.stop()
                return
            }
            demoStart = nil
            guard let port else { return }
            demoPort = port
            connect()
        }
    }

    /// Stop, a hidden tab.
    func stop() {
        source.stop()
    }

    /// The tab closed: the demo server goes too.
    func close() {
        closed = true
        source.stop()
        demoStart?.cancel()
        demo?.stop()
        demo = nil
    }

    /// Reconnect or Sign In pressed. After a sign-in failure it asks for the
    /// user name and password first, in a sheet on `window`.
    func reconnect(in window: NSWindow?) {
        if case .ended(.signInRequired) = source.status.state {
            promptForSignIn(in: window)
        } else {
            connect()
        }
    }

    private func promptForSignIn(in window: NSWindow?) {
        guard !prompting else { return }
        prompting = true
        let saved = store.credentials(for: endpoint)
        let alert = NSAlert()
        alert.messageText = RemoteVNCStrings.signInTitle(record.host)
        alert.informativeText = RemoteVNCStrings.signInMessage
        alert.addButton(withTitle: RemoteVNCStrings.connect)
        alert.addButton(withTitle: RemoteVNCStrings.cancel)
        let user = NSTextField(string: saved?.username ?? "")
        user.placeholderString = RemoteVNCStrings.userPlaceholder
        let password = NSSecureTextField(string: "")
        password.placeholderString = RemoteVNCStrings.passwordPlaceholder
        let stack = NSStackView(views: [user, password])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = saved?.username == nil ? user : password
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            prompting = false
            let credentials = VNCCredentials(username: user.stringValue, password: password.stringValue)
            guard response == .alertFirstButtonReturn, credentials.password != nil else {
                // Cancel keeps the sign-in card.
                source.republishStatus()
                return
            }
            // Saved only once the host accepts them, so a typo never replaces a working sign-in.
            let store = store, endpoint = endpoint
            source.connect(to: endpoint, credentials: credentials) { store.save(credentials, for: endpoint) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}

/// Strings of the VNC sign-in sheet (Resources/Remote.xcstrings).
@MainActor
struct RemoteVNCStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Remote", bundle: .module)
    }

    static func signInTitle(_ host: String) -> String {
        String(format: t("remote.vnc.signIn.title", "Sign in to %@"), host)
    }

    static var signInMessage: String {
        t("remote.vnc.signIn.message", "Enter the user name and password of this computer's screen sharing. For a Mac, use an account on that Mac. cmux keeps them in your keychain.")
    }

    static var userPlaceholder: String { t("remote.vnc.signIn.user", "User name (optional for VNC passwords)") }
    static var passwordPlaceholder: String { t("remote.vnc.signIn.password", "Password") }
    static var connect: String { t("remote.vnc.signIn.connect", "Connect") }
    static var cancel: String { t("remote.vnc.signIn.cancel", "Cancel") }
}
#endif
