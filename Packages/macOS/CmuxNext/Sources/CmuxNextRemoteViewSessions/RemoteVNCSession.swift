public import AppKit
import CmuxNextDesign
public import CmuxNextWakeups
public import CmuxNextRemoteView
public import CmuxVNC
import CmuxVNCDemoServer

#if DEBUG
/// The VNC side of a `remote_view` tab whose record says `via=vnc`: the
/// source, the saved sign-in, the sign-in prompt, and, for the host `mock`,
/// an in-process loopback demo server (the VNC test desktop).
@MainActor
public final class RemoteVNCSession {
    public let record: RemoteViewTabRecord
    public let source = RemoteVNCSource()
    /// The record's address; the Keychain key for its sign-in.
    public let endpoint: VNCEndpoint
    private let store = RemoteVNCCredentialStore()
    /// The app's lanes: every Keychain call of the sign-in runs on their system lane, never on main.
    private let work: BackgroundWork
    /// Where a saved sign-in's read answers on main.
    private let mainWork: MainWorkScheduler
    /// The newest saved sign-in read: an answer from an older read, or one after `stop` or `close`, is dropped.
    private var credentialRead = 0
    private var demo: VNCDemoServer?
    private var demoPort: UInt16?
    private var demoStart: Task<Void, Never>?
    private var prompting = false
    private var closed = false

    /// `demoHost`: the reserved host name served by the loopback demo desktop; `work` and `mainWork`: the app's
    /// lanes and main-thread scheduler (the Keychain reads and writes of the sign-in, and their answers).
    public init(record: RemoteViewTabRecord, port: UInt16, demoHost: String, work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.record = record
        self.work = work
        self.mainWork = mainWork
        // The reserved names (RemoteViewTabPolicy) are never resolved: `local` and
        // `localhost` are this Mac, `mock` is the loopback demo desktop.
        let host = record.host.lowercased()
        endpoint = VNCEndpoint(host: ["local", "localhost"].contains(host) ? "127.0.0.1" : record.host, port: port)
        if host == demoHost { demo = VNCDemoServer() }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            demoStart?.cancel()
            demo?.stop()
        }
    }

    /// Connects with the saved sign-in (or none; the host may not need one).
    public func connect() {
        guard !closed else { return }
        guard let demo else {
            // The saved sign-in comes from the Keychain on the system lane; the connect follows it.
            readSavedSignIn { [weak self] saved in
                guard let self else { return }
                source.connect(to: endpoint, credentials: saved ?? VNCCredentials())
            }
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
    public func stop() {
        credentialRead += 1
        source.stop()
    }

    /// The tab closed: the demo server goes too.
    public func close() {
        closed = true
        credentialRead += 1
        source.stop()
        demoStart?.cancel()
        demo?.stop()
        demo = nil
    }

    /// Reconnect or Sign In pressed. After a sign-in failure it asks for the
    /// user name and password first, in a sheet on `window`.
    public func reconnect(in window: NSWindow?) {
        if case .ended(.signInRequired) = source.status.state {
            promptForSignIn(in: window)
        } else {
            connect()
        }
    }

    private func promptForSignIn(in window: NSWindow?) {
        guard !prompting else { return }
        prompting = true
        // The saved user name fills the sheet: read on the system lane, then the sheet shows.
        readSavedSignIn(dropped: { [weak self] in self?.prompting = false }) { [weak self, weak window] saved in
            self?.presentSignIn(saved: saved, in: window)
        }
    }

    /// Reads the saved sign-in on the system lane (a person waits for it) and gives it to `then` on main, unless
    /// a newer read, `stop` or `close` came first; then `dropped` runs instead.
    private func readSavedSignIn(dropped: @escaping @MainActor @Sendable () -> Void = {},
                                 then: @escaping @MainActor @Sendable (VNCCredentials?) -> Void) {
        credentialRead += 1
        let read = credentialRead, store = store, endpoint = endpoint
        work.run(.userBlocking, mayBlock: .system) { store.credentials(for: endpoint) }
            .reply(on: mainWork, class: .visible, owner: "remoteVNC.savedSignIn") { [weak self] saved in
                guard let self, !closed, read == credentialRead else { return dropped() }
                then(saved)
            }
    }

    private func presentSignIn(saved: VNCCredentials?, in window: NSWindow?) {
        let spec = CmuxDialogSpec(
            title: RemoteVNCStrings.signInTitle(record.host),
            lines: [RemoteVNCStrings.signInMessage],
            fields: [
                .text(id: Self.userField, label: nil, initial: saved?.username ?? "",
                      placeholder: RemoteVNCStrings.userPlaceholder, secure: false),
                .text(id: Self.passwordField, label: nil, initial: "",
                      placeholder: RemoteVNCStrings.passwordPlaceholder, secure: true),
            ],
            buttons: [.cancel(RemoteVNCStrings.cancel),
                      CmuxDialogButton(id: Self.connectButton, title: RemoteVNCStrings.connect, role: .default)],
            identifier: "remote.vnc.signIn")
        let scope: CmuxDialogScope = window.map { .window($0) } ?? .app
        CmuxDialogCenter.shared.present(spec, in: scope) { [weak self] answer in
            guard let self else { return }
            prompting = false
            let credentials = VNCCredentials(username: answer.text(Self.userField), password: answer.text(Self.passwordField))
            guard answer.button == Self.connectButton, !answer.isDismissal, credentials.password != nil else {
                // Cancel keeps the sign-in card.
                source.republishStatus()
                return
            }
            // Saved only once the host accepts them, so a typo never replaces a working sign-in; the
            // Keychain write runs on the system lane.
            let store = store, endpoint = endpoint, work = work
            source.connect(to: endpoint, credentials: credentials) {
                work.post(.bestEffort, mayBlock: .system) { store.save(credentials, for: endpoint) }
            }
        }
    }

    private static let userField = "user"
    private static let passwordField = "password"
    private static let connectButton = "connect"
}

/// Strings of the VNC sign-in sheet (Resources/RemoteViewSessions.xcstrings).
@MainActor
struct RemoteVNCStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "RemoteViewSessions", bundle: .module)
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
