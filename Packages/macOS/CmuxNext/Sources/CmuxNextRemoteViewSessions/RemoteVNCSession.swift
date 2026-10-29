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
    /// A Cloud machine's desktop: a fresh transport over the app's Cloud tunnel per session.
    private let makeTransport: (@Sendable () -> any RFBTransport)?
    /// The app's lanes: every Keychain call of the sign-in runs on their system lane, never on main.
    private let work: BackgroundWork
    /// The saved sign-in reads: memory first, else the system lane; a newer read, `stop` or `close` drops an older one.
    private let signInReads: RemoteVNCSignInReads
    private var demo: VNCDemoServer?
    private var demoPort: UInt16?
    private var demoStart: Task<Void, Never>?
    private var prompting = false
    private var closed = false
    /// The app's scheduler: the demo server's start answers in its userBlocking class (the person opened the tab).
    private let mainWork: MainWorkScheduler

    /// `demoHost`: the reserved host name served by the loopback demo desktop; `work` and `mainWork`: the app's
    /// lanes and main-thread scheduler (the Keychain reads and writes of the sign-in, and their answers);
    /// `signIns`: the app's saved VNC sign-ins in memory.
    public init(record: RemoteViewTabRecord, port: UInt16, demoHost: String, work: BackgroundWork, mainWork: MainWorkScheduler,
                signIns: RemoteVNCSignIns) {
        self.record = record
        self.work = work
        self.mainWork = mainWork
        makeTransport = nil
        // The reserved names (RemoteViewTabPolicy) are never resolved: `local` and
        // `localhost` are this Mac, `mock` is the loopback demo desktop.
        let host = record.host.lowercased()
        let endpoint = VNCEndpoint(host: ["local", "localhost"].contains(host) ? "127.0.0.1" : record.host, port: port)
        self.endpoint = endpoint
        signInReads = RemoteVNCSignInReads(work: work, mainWork: mainWork, memory: signIns, account: endpoint.label,
                                           keychain: { RemoteVNCCredentialStore().keychainCredentials(for: endpoint) },
                                           fallback: { RemoteVNCCredentialStore().debugFileCredentials() })
        if host == demoHost { demo = VNCDemoServer() }
    }

    /// A Cloud machine's desktop (`via=cloud`): its VNC server, reached by `makeTransport`. `work`, `mainWork` and
    /// `signIns` as for a VNC host (a Cloud desktop asks no sign-in: its transport carries the machine's own).
    public init(cloudRecord record: RemoteViewTabRecord, makeTransport: @escaping @Sendable () -> any RFBTransport,
                work: BackgroundWork, mainWork: MainWorkScheduler, signIns: RemoteVNCSignIns) {
        self.record = record
        self.makeTransport = makeTransport
        self.work = work
        self.mainWork = mainWork
        let endpoint = VNCEndpoint(host: record.host, port: 5901)
        self.endpoint = endpoint
        signInReads = RemoteVNCSignInReads(work: work, mainWork: mainWork, memory: signIns, account: endpoint.label,
                                           keychain: { RemoteVNCCredentialStore().keychainCredentials(for: endpoint) },
                                           fallback: { RemoteVNCCredentialStore().debugFileCredentials() })
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
        guard makeTransport != nil, !closed, retry == nil else { return }
        let wait = Duration.seconds(min(10, 1 << min(lostTries, 3)))
        lostTries += 1
        retry = Task { [weak self] in
            // wakeup-allow: one cancellable backoff wait before a reconnect; Stop and close cancel it.
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            retry = nil
            connect()
        }
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
        if let makeTransport {
            source.connect(to: endpoint, credentials: VNCCredentials(), transport: makeTransport()) { [weak self] in
                Task { @MainActor in self?.lostTries = 0 }
            }
            return
        }
        guard let demo else {
            // The saved sign-in comes from memory or the Keychain on the system lane; the connect follows it.
            signInReads.read { [weak self] saved in
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
        let mainWork = mainWork
        // The server starts off main; its port is one userBlocking task (the rest of the person's open, Chrome's
        // PostTaskAndReply).
        // task-owner: the demo server's start; ends with its port, or at close().
        demoStart = Task { @concurrent [weak self] in
            let port = try? await demo.start()
            mainWork.postFromAnyThread(.userBlocking, owner: "remote-view.vnc-demo") { [weak self] in
                // Closed (or gone) while the server started: stop it, never connect.
                guard let self, !closed else {
                    demo.stop()
                    return
                }
                demoStart = nil
                guard let port else { return }
                demoPort = port
                connect()
            }
        }
    }

    /// Stop, a hidden tab.
    public func stop() {
        retry?.cancel()
        retry = nil
        signInReads.cancel()
        source.stop()
    }

    /// The tab closed: the demo server goes too.
    public func close() {
        closed = true
        retry?.cancel()
        retry = nil
        signInReads.cancel()
        source.stop()
        demoStart?.cancel()
        demo?.stop()
        demo = nil
    }

    /// Reconnect or Sign In pressed. After a sign-in failure it asks for the
    /// user name and password first, in a sheet on `window`.
    public func reconnect(in window: NSWindow?) {
        // A Cloud desktop only ever goes over the app's Cloud tunnel: no sign-in sheet, whose
        // connect would be plain TCP to the record's host.
        if makeTransport == nil, case .ended(.signInRequired) = source.status.state {
            promptForSignIn(in: window)
        } else {
            connect()
        }
    }

    private func promptForSignIn(in window: NSWindow?) {
        guard !prompting else { return }
        prompting = true
        // The saved user name fills the sheet: from memory or a system lane read, then the sheet shows.
        signInReads.read(dropped: { [weak self] in self?.prompting = false }) { [weak self, weak window] saved in
            self?.presentSignIn(saved: saved, in: window)
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
            let store = store, endpoint = endpoint, work = work, signInReads = signInReads
            source.connect(to: endpoint, credentials: credentials) {
                signInReads.saved(credentials)
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
