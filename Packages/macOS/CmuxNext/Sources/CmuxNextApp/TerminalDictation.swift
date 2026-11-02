import AppKit
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDictation
import CmuxNextTerminal

/// Dictation for a terminal surface. Finalized words go through the daemon's
/// paste path so local, SSH, and Cloud terminals all receive the same safe
/// bracketed paste. The surface and daemon are pinned until the session ends.
@MainActor
final class TerminalDictation {
    private let claims: DictationMicrophoneClaims
    private let makeSession: () -> DictationSession
    private var session: DictationSession?
    private var targetSurface: SurfaceID?
    private var targetDaemon: DaemonService?
    private weak var targetHost: TerminalHostView?
    private var committedText = ""
    private let preview = TerminalDictationPreview()

    init(
        claims: DictationMicrophoneClaims = .shared,
        makeSession: @escaping () -> DictationSession = { TerminalDictation.defaultSession() }
    ) {
        self.claims = claims
        self.makeSession = makeSession
    }

    var isActive: Bool { session?.phase.isStartable == false }

    /// Toggles the pinned terminal. Once started, a later invocation on a
    /// different tab stops this session rather than retargeting its words.
    func toggle(entry: TerminalEntry, surface: SurfaceID, daemon: DaemonService) {
        guard !isActive else {
            session?.stop()
            return
        }
        start(entry: entry, surface: surface, daemon: daemon)
    }

    /// Stops a running terminal session when the shortcut is invoked after
    /// focus moved away from its terminal.
    @discardableResult
    func stopIfActive() -> Bool {
        guard isActive else { return false }
        session?.stop()
        return true
    }

    /// The owner (the action registry) is discarded with the app services.
    func close() {
        session?.cancel()
        session?.onUpdate = nil
        session?.onFinalText = nil
        claims.release(self)
        clearTarget()
    }

    private func start(entry: TerminalEntry, surface: SurfaceID, daemon: DaemonService) {
        let session = activeSession()
        targetSurface = surface
        targetDaemon = daemon
        targetHost = entry.session.view
        committedText = ""
        targetHost?.topOverlay = preview
        claims.claim(self) { [weak self] in self?.session?.stop() }
        session.start()
    }

    private func activeSession() -> DictationSession {
        if let session { return session }
        let made = makeSession()
        made.onFinalText = { [weak self] delta in self?.insert(delta) }
        made.onUpdate = { [weak self] update in self?.deliver(update) }
        session = made
        return made
    }

    private func insert(_ delta: String) {
        guard let surface = targetSurface, let daemon = targetDaemon else { return }
        committedText += delta
        daemon.send("dictation") { try await $0.send(surface, text: delta, paste: true) }
    }

    private func deliver(_ update: DictationUpdate) {
        guard !update.phase.isStartable else {
            preview.hide()
            clearTarget()
            claims.release(self)
            return
        }
        let volatile: String
        if update.text.hasPrefix(committedText) {
            volatile = String(update.text.dropFirst(committedText.count))
        } else {
            volatile = update.text
        }
        preview.show(volatileText: volatile.trimmingCharacters(in: .whitespaces))
        targetHost?.needsLayout = true
    }

    private func clearTarget() {
        targetHost?.topOverlay = nil
        targetHost = nil
        targetSurface = nil
        targetDaemon = nil
        committedText = ""
    }

    static func defaultSession() -> DictationSession {
        #if DEBUG
        if let recorded = DictationSession.recorded() { return recorded }
        #endif
        return DictationSession()
    }
}
