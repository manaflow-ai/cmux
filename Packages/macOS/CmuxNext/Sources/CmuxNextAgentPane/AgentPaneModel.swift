public import Foundation
public import Observation

/// One agent pane's host-side state: which acpmux session it shows. The
/// session, its transcript and every chat action live in acpmux and the
/// page; this only answers the page's host requests.
@Observable
public final class AgentPaneModel {
    /// The session the page last reported, nil for a new chat that has not
    /// sent its first prompt.
    public private(set) var sessionId: String?
    /// The last handshake failure shown to the page, for diagnostics.
    public private(set) var lastError: String?
    /// Page projection of its single session-host Git capability read, never an authorization grant.
    public private(set) var checkpointAvailable = false
    @ObservationIgnored public var onCheckpointAvailability: ((Bool) -> Void)?

    /// Called when the page switches to or creates a session, so the App can
    /// keep it with the tab.
    @ObservationIgnored public var onSessionChange: ((String) -> Void)?
    /// Gets each settled transcript scroll's frame intervals (milliseconds).
    @ObservationIgnored public var onFramePacing: (([Double]) -> Void)?
    /// The new tab page this pane shows until it has a session, nil for a
    /// plain chat. Cleared once the page reports a session.
    public private(set) var newTab: AgentPaneNewTab?
    /// The new tab page chose a terminal or browser (`tab.open`).
    @ObservationIgnored public var onOpenTab: ((AgentPaneTabKind, String, String?) -> Void)?
    /// The location bar picked an open tab or workspace (`tab.jump`).
    @ObservationIgnored public var onJump: ((AgentPaneJumpTarget, String) -> Void)?
    /// The new tab page asked to change a kind's shortcut.
    @ObservationIgnored public var onEditShortcut: ((AgentPaneTabKind) -> Void)?
    /// The new tab page's "default: X" toggle (`tab.setDefaultKind`).
    @ObservationIgnored public var onSetDefaultKind: ((String) -> Void)?
    /// Gets the composer's dictation requests (the pane's mic).
    @ObservationIgnored public var onDictation: ((AgentPaneDictationCommand) -> Void)?
    /// Opens a changed file the page names; false when it could not.
    @ObservationIgnored public var onOpenFile: (@MainActor (URL, AgentPaneFileTarget) async -> Bool)?
    /// The quick panel's page asked to hide the panel (`quick.dismiss`).
    @ObservationIgnored public var onQuickDismiss: (() -> Void)?
    /// The quick panel's page asked to open its chat in the main window
    /// (`quick.openInWindow`). Gets the chat's session, nil before the
    /// first prompt.
    @ObservationIgnored public var onQuickOpenInWindow: ((String?) -> Void)?
    /// This build's URL scheme, handed to the page with every handshake so
    /// the links it copies open in this build; nil leaves it out.
    @ObservationIgnored public var linkScheme: String?
    /// Set for a tab a `cmux://session/<id>` link opened: the handshake asks
    /// the page to refuse a session the daemon does not have rather than
    /// show the most recent one. Cleared once the page reports a session.
    @ObservationIgnored public var sessionMustExist = false
    /// A `#turn-<turnId>` link's turn the page has not been handed yet; the
    /// next handshake carries it (`revealTurn`) and clears it.
    @ObservationIgnored public var pendingRevealTurn: String?
    /// Whether the page has asked for a handshake, so its bridge is up and
    /// a turn can be revealed through it directly.
    @ObservationIgnored public private(set) var hasHandshake = false
    /// Runs a git read on the session host and returns its JSON result.
    /// Throws an ``AgentPaneGitFailure`` saying who failed; any other error
    /// reaches the page as `native.failed`.
    @ObservationIgnored public var onGit: (@MainActor (AgentPaneGitRequest) async throws -> Data)?
    /// Runs a commit or push on the session host in the given folder (the
    /// pane's session's, from the host) and returns its `MutationResult` as
    /// JSON; throws like ``onGit``.
    @ObservationIgnored public var onGitWrite: (@MainActor (AgentPaneGitWrite, String) async throws -> Data)?

    @ObservationIgnored private let host: any AgentPaneHostProviding
    /// What a new chat inherits from the tab it was opened from.
    @ObservationIgnored private let seed: AgentPaneSeedSource?

    public init(
        host: any AgentPaneHostProviding,
        sessionId: String? = nil,
        seed: AgentPaneSeedSource? = nil,
        newTab: AgentPaneNewTab? = nil
    ) {
        self.host = host
        self.sessionId = sessionId
        self.seed = seed
        self.newTab = sessionId == nil ? newTab : nil
    }

    /// The reply for one page request.
    public func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .ready, .reconnect:
            setCheckpointAvailable(false)
            do {
                var handshake = request == .ready
                    ? try await host.handshake(sessionId: sessionId)
                    : try await host.reconnectHandshake(sessionId: sessionId)
                // Only a chat without a session yet starts from the seed.
                if sessionId == nil, let seed = await seed?.take() {
                    handshake.cwd = seed.cwd
                    handshake.draft = seed.draft
                    handshake.prompt = seed.prompt
                    handshake.adopt = seed.adopt
                }
                // The surface holds after the chat has a session (a reload
                // of the quick panel stays compact).
                handshake.surface = seed?.surface
                // A new tab page is a new chat on every host, the mock included: the page
                // never falls back to the most recent session behind it. Its chat starts in
                // the page's folder unless a seed named one.
                if sessionId == nil, let newTab {
                    handshake.newTab = newTab
                    handshake.newSession = true
                    if handshake.cwd == nil { handshake.cwd = newTab.cwd }
                }
                handshake.linkScheme = linkScheme
                if sessionMustExist, sessionId != nil { handshake.sessionMustExist = true }
                handshake.revealTurn = pendingRevealTurn
                pendingRevealTurn = nil
                hasHandshake = true
                lastError = nil
                return AgentPaneReply.handshake(handshake)
            } catch {
                let message = AgentPaneHostError.userMessage(for: error)
                lastError = message
                return AgentPaneReply.failure(code: "host_unavailable", message: message)
            }
        case .persistSession(let id):
            sessionMustExist = false
            if id != sessionId {
                sessionId = id
                newTab = nil
                onSessionChange?(id)
            }
            return AgentPaneReply.success()
        case .checkpointAvailability(let available):
            setCheckpointAvailable(available)
            return AgentPaneReply.success()
        case .framePacing(let intervals):
            onFramePacing?(intervals)
            return AgentPaneReply.success()
        case .openTab(let kind, let text, let cwd):
            guard newTab != nil, let onOpenTab else { return Self.unsupported("tab.open") }
            onOpenTab(kind, text, cwd)
            return AgentPaneReply.success()
        case .jump(let target, let id):
            guard newTab != nil, let onJump else { return Self.unsupported("tab.jump") }
            onJump(target, id)
            return AgentPaneReply.success()
        case .setDefaultKind(let kind):
            guard newTab != nil, let onSetDefaultKind else { return Self.unsupported("tab.setDefaultKind") }
            onSetDefaultKind(kind)
            return AgentPaneReply.success()
        case .editShortcut(let kind):
            guard let onEditShortcut else { return Self.unsupported("shortcut.edit") }
            onEditShortcut(kind)
            return AgentPaneReply.success()
        case .dictation(let command):
            guard let onDictation else { return AgentPaneReply.failure(code: "unsupported", message: "Dictation is unavailable") }
            onDictation(command)
            return AgentPaneReply.success()
        case .openFile(let path, let target):
            guard let onOpenFile, let url = AgentPaneFileOpen.resolve(path),
                  target == .editor || AgentPaneFileOpen.showsInTab(url), await onOpenFile(url, target) else {
                return AgentPaneReply.failure(code: "open_failed", message: Self.openFileFailedMessage)
            }
            return AgentPaneReply.success()
        case .quickDismiss:
            guard let onQuickDismiss else { return Self.unsupported("quick.dismiss") }
            onQuickDismiss()
            return AgentPaneReply.success()
        case .quickOpenInWindow(let session):
            guard let onQuickOpenInWindow else { return Self.unsupported("quick.openInWindow") }
            if let session, session != sessionId {
                sessionId = session
                newTab = nil
                onSessionChange?(session)
            }
            onQuickOpenInWindow(sessionId)
            return AgentPaneReply.success()
        case .git(let git):
            guard let onGit else { return Self.gitFailure(.notConnected) }
            return await Self.gitReply(message: Self.gitFailedMessage) { try await onGit(git) }
        case .gitWrite(let write):
            guard let onGitWrite else { return Self.gitFailure(.notConnected, message: Self.gitWriteFailedMessage) }
            // The pane's own session, never a folder the page names.
            guard let sessionId else { return Self.gitFailure(.noSessionFolder, message: Self.gitWriteFailedMessage) }
            let folder: AgentPaneSessionFolder?
            do {
                folder = try await host.sessionFolder(sessionId: sessionId)
            } catch {
                return Self.gitFailure(.notConnected, message: Self.gitWriteFailedMessage)
            }
            guard let folder, folder.isLocal, folder.cwd.hasPrefix("/") else {
                return Self.gitFailure(.noSessionFolder, message: Self.gitWriteFailedMessage)
            }
            return await Self.gitReply(message: Self.gitWriteFailedMessage) { try await onGitWrite(write, folder.cwd) }
        case .invalidGit(let method):
            let message = method == "git.commit" || method == "git.push" ? Self.gitWriteFailedMessage : Self.gitFailedMessage
            return Self.gitFailure(.invalidRequest, message: message)
        case .unsupported(let method):
            return Self.unsupported(method)
        }
    }

    private static func unsupported(_ method: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
    }

    private func setCheckpointAvailable(_ available: Bool) {
        guard checkpointAvailable != available else { return }
        checkpointAvailable = available
        onCheckpointAvailability?(available)
    }
}

extension AgentPaneModel {
    /// The page's reply for a failed git read: the failure's code, origin,
    /// details and retryable under the localized text.
    static func gitFailure(_ failure: AgentPaneGitFailure, message: String = gitFailedMessage) -> [String: Any] {
        let details = failure.details.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        return AgentPaneReply.failure(
            code: failure.code, message: message, details: details,
            retryable: failure.retryable, origin: failure.origin.rawValue)
    }

    /// The page's reply for a git read or write: its JSON result, else the
    /// failure under `message`. A result that is not JSON is `native.failed`.
    static func gitReply(message: String, _ run: () async throws -> Data) async -> [String: Any] {
        do {
            let data = try await run()
            guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return gitFailure(.failed, message: message)
            }
            return AgentPaneReply.success(value)
        } catch {
            return gitFailure(error as? AgentPaneGitFailure ?? .failed, message: message)
        }
    }
}
