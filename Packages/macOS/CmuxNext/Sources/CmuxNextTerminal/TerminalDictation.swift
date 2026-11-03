import AppKit
public import CmuxNextDictation

/// Dictation for a terminal surface. Finalized words go to the `paste` the
/// owner gives (the App sends them through the daemon's paste path, so local,
/// SSH and Cloud terminals all receive the same safe bracketed paste). The
/// host and its paste target are pinned until the session ends.
@MainActor
public final class TerminalDictation {
    private let claims: DictationMicrophoneClaims
    private let makeSession: () -> DictationSession
    private var session: DictationSession?
    private var targetPaste: (@MainActor (String) -> Void)?
    private weak var targetHost: TerminalHostView?
    private let preview = TerminalDictationPreview()

    public init(
        claims: DictationMicrophoneClaims = .shared,
        makeSession: @escaping () -> DictationSession = { TerminalDictation.defaultSession() }
    ) {
        self.claims = claims
        self.makeSession = makeSession
    }

    public var isActive: Bool { session?.phase.isStartable == false }

    /// Toggles the pinned terminal. Once started, a later invocation on a
    /// different tab stops this session rather than retargeting its words.
    /// `paste` receives each finalized segment for `host`'s terminal.
    public func toggle(host: TerminalHostView, paste: @escaping @MainActor (String) -> Void) {
        guard !isActive else {
            session?.stop()
            return
        }
        start(host: host, paste: paste)
    }

    /// Stops a running terminal session when the shortcut is invoked after
    /// focus moved away from its terminal.
    @discardableResult
    public func stopIfActive() -> Bool {
        guard isActive else { return false }
        session?.stop()
        return true
    }

    /// Ends the session and drops it (its pinned host closed). The next toggle makes a fresh
    /// session with its callbacks, so a terminal closed mid-dictation never ends dictation for the app.
    func close() {
        session?.cancel()
        session?.onUpdate = nil
        session?.onFinalText = nil
        session = nil
        claims.release(self)
        clearTarget()
    }

    private func start(host: TerminalHostView, paste: @escaping @MainActor (String) -> Void) {
        let session = activeSession()
        targetPaste = paste
        targetHost = host
        targetHost?.onClose = { [weak self, weak host = targetHost] in
            guard let self, self.targetHost === host else { return }
            self.close()
        }
        targetHost?.topOverlay = preview
        claims.claim(self) { [weak self] in self?.session?.stop() }
        session.start()
    }

    private func activeSession() -> DictationSession {
        if let session { return session }
        let made = makeSession()
        made.onFinalText = { [weak self] delta in self?.targetPaste?(delta) }
        made.onUpdate = { [weak self] update in self?.deliver(update) }
        session = made
        return made
    }

    private func deliver(_ update: DictationUpdate) {
        guard !update.phase.isStartable else {
            preview.hide()
            clearTarget()
            claims.release(self)
            return
        }
        // The session's own split (DictationTranscript): only words not pasted yet show.
        preview.show(volatileText: (session?.volatileText ?? "").trimmingCharacters(in: .whitespaces))
        targetHost?.needsLayout = true
    }

    private func clearTarget() {
        targetHost?.onClose = nil
        targetHost?.topOverlay = nil
        targetHost = nil
        targetPaste = nil
    }

    public static func defaultSession() -> DictationSession {
        #if DEBUG
        if let recorded = DictationSession.recorded() { return recorded }
        #endif
        return DictationSession()
    }
}
