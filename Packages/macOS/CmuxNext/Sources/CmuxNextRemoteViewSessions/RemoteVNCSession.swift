public import AppKit
import CmuxNextCompat
import CmuxNextDesign
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
    /// The app's one guard of the Keychain UI switch (``RemoteViewPageSession/useLoginKeychain(_:)``),
    /// set before the first connect; without it no saved sign-in is read or saved.
    var loginKeychain: LoginKeychain?
    private var store: RemoteVNCCredentialStore? { loginKeychain.map(RemoteVNCCredentialStore.init(loginKeychain:)) }
    /// A Cloud machine's desktop: a fresh transport over the app's Cloud tunnel per session.
    private let makeTransport: (@Sendable () -> any RFBTransport)?
    private var demo: VNCDemoServer?
    private var demoPort: UInt16?
    private var demoStart: Task<Void, Never>?
    private var prompting = false
    private var closed = false
    /// Stop (a hidden tab) until the next connect: a queued loss reconnects nothing meanwhile.
    private var stopped = false

    /// `demoHost`: the reserved host name served by the loopback demo desktop.
    public init(record: RemoteViewTabRecord, port: UInt16, demoHost: String) {
        self.record = record
        makeTransport = nil
        // The reserved names (RemoteViewTabPolicy) are never resolved: `local` and
        // `localhost` are this Mac, `mock` is the loopback demo desktop.
        let host = record.host.lowercased()
        endpoint = VNCEndpoint(host: ["local", "localhost"].contains(host) ? "127.0.0.1" : record.host, port: port)
        if host == demoHost { demo = VNCDemoServer() }
    }

    /// A Cloud machine's desktop (`via=cloud`): its VNC server, reached by `makeTransport`.
    public init(cloudRecord record: RemoteViewTabRecord, makeTransport: @escaping @Sendable () -> any RFBTransport) {
        self.record = record
        self.makeTransport = makeTransport
        endpoint = VNCEndpoint(host: record.host, port: 5901)
        // A lost path to a Cloud desktop reconnects by itself (the tunnel or the machine's link
        // blinked); a Stop, a sign-in refusal or a closed tab does not.
        source.onEnded { [weak self] end in
            guard case .connectionLost = end else { return }
            Task { @MainActor in self?.reconnectAfterLoss() }
        }
    }

    /// Tries since the last session that streamed; sets the next wait (1, 2, 4, 8, then 10 s).
    private var lostTries = 0
    private var retry: Task<Void, Never>?

    private func reconnectAfterLoss() {
        guard makeTransport != nil, !closed, !stopped, retry == nil else { return }
        // The loss is queued onto the main actor. A manual reconnect that ran first started a new
        // session (its status is no longer this loss), so the queued loss schedules nothing.
        guard case .ended(.connectionLost) = source.status.state else { return }
        let wait = Duration.seconds(min(10, 1 << min(lostTries, 3)))
        lostTries += 1
        scheduleRetry(after: wait)
    }

    private func scheduleRetry(after wait: Duration) {
        guard !closed, retry == nil else { return }
        retry = Task { [weak self] in
            // wakeup-allow: one cancellable backoff wait before a reconnect; Stop and close cancel it.
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            retry = nil
            connect()
        }
    }

#if DEBUG
    /// Test seam for the race where a manual reconnect supersedes an automatic retry.
    internal var hasPendingRetryForTesting: Bool { retry != nil }

    /// The pending automatic retry, so a test can await its end instead of sleeping past it.
    internal var pendingRetryForTesting: Task<Void, Never>? { retry }

    internal func scheduleAutomaticRetryForTesting(after wait: Duration) {
        scheduleRetry(after: wait)
    }

    /// Runs a lost-path callback that was queued before a manual reconnect.
    internal func deliverQueuedLossForTesting() {
        reconnectAfterLoss()
    }
#endif

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
        stopped = false
        if let makeTransport {
            source.connect(to: endpoint, credentials: VNCCredentials(), transport: makeTransport()) { [weak self] in
                Task { @MainActor in self?.lostTries = 0 }
            }
            return
        }
        guard let demo else {
            source.connect(to: endpoint, credentials: store?.credentials(for: endpoint) ?? VNCCredentials())
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
        stopped = true
        cancelRetry()
        source.stop()
    }

    /// The tab closed: the demo server goes too.
    public func close() {
        closed = true
        cancelRetry()
        source.stop()
        demoStart?.cancel()
        demo?.stop()
        demo = nil
    }

    /// Reconnect or Sign In pressed. After a sign-in failure it asks for the
    /// user name and password first, in a sheet on `window`.
    public func reconnect(in window: NSWindow?) {
        // A manual reconnect supersedes any delayed automatic retry. Otherwise the stale task
        // can reconnect again after this attempt succeeds and replace the healthy connection.
        cancelRetry()
        // A Cloud desktop only ever goes over the app's Cloud tunnel: no sign-in sheet, whose
        // connect would be plain TCP to the record's host.
        if makeTransport == nil, case .ended(.signInRequired) = source.status.state {
            promptForSignIn(in: window)
        } else {
            connect()
        }
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func promptForSignIn(in window: NSWindow?) {
        guard !prompting else { return }
        prompting = true
        let saved = store?.credentials(for: endpoint)
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
            // Saved only once the host accepts them, so a typo never replaces a working sign-in.
            let store = store, endpoint = endpoint
            source.connect(to: endpoint, credentials: credentials) { store?.save(credentials, for: endpoint) }
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
