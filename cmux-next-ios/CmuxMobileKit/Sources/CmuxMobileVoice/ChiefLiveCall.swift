#if os(iOS)
import AVFoundation
public import CmuxMobileChief
public import CmuxMobileModel
public import CmuxMobileRealtime
import CryptoKit
import Foundation
import Observation

/// The app's live Chief call: starts it (or says a key is missing), holds
/// the one call that may run at a time, minimizes it to the pill and back,
/// and passes the called Chief's new chat messages to the call while it runs.
///
/// A call is to one Chief, the one the user called (``start(chief:)``), and
/// sees and writes only that Chief's conversation (``ChiefCallToolbox``).
///
/// The call talks to OpenAI's Realtime API from the phone with the user's
/// own key (Settings → Chief Calls); the key is read from the Keychain for
/// each call and is not kept in memory between calls.
@MainActor
@Observable
public final class ChiefLiveCall {
    public static let shared = ChiefLiveCall()

    /// The current or just-ended call; nil once its screen is closed.
    public private(set) var session: VoiceCallSession?
    /// The call runs with its screen closed; the shell shows the pill.
    public var isMinimized = false
    /// The call screen is up.
    public var showsScreen: Bool { session != nil && !isMinimized }
    /// The Chief this call is to; nil with no call.
    public private(set) var chief: ChiefSession?
    /// Its name and avatar, as they were when the call started.
    public private(set) var chiefName = "Chief"
    public private(set) var chiefAvatar = "C"

    @ObservationIgnored public let keys: OpenAIKeyModel
    @ObservationIgnored public let preferences: VoiceCallPreferences
    @ObservationIgnored private let sources: ChiefSources
    @ObservationIgnored private var store: AppStore?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var userName: String?
    /// Chief messages already passed to (or present before) the call.
    @ObservationIgnored private var seenChiefMessages: Set<String> = []
    @ObservationIgnored private var toolbox: ChiefCallToolbox?

    public init(sources: ChiefSources = .shared, keys: OpenAIKeyModel = .shared,
                preferences: VoiceCallPreferences = .shared) {
        self.sources = sources
        self.keys = keys
        self.preferences = preferences
    }

    /// The signed-in shell's data; a sign-out ends a running call.
    public func configure(store: AppStore, accountID: String?, userName: String?) {
        self.store = store
        self.userName = userName
        if accountID != self.accountID {
            self.accountID = accountID
            keys.selectAccount(accountID)
            if let session, !session.hasEnded { session.hangUp() }
            session = nil
            chief = nil
            toolbox = nil
            #if DEBUG
            // Simulator verification: CMUX_MOBILE_CALL_SEED_KEY stores that key unchecked (the real
            // WebRTC path against OpenAI); the scripted demo call stores a placeholder that only
            // passes the key gate. Neither exists outside DEBUG builds.
            if accountID != nil, !keys.hasKey {
                if let seed = ProcessInfo.processInfo.environment["CMUX_MOBILE_CALL_SEED_KEY"], !seed.isEmpty {
                    keys.storeForDemo(seed)
                } else if ScriptedVoiceCallLink.requested() != nil {
                    keys.storeForDemo("sk-demo-scripted-call-0000")
                }
            }
            #endif
        }
    }

    /// Calls `chief`, or brings back the call to it that runs. A call to another
    /// Chief ends first: a call is never to one Chief while the user asked for
    /// another. Nil (the Action Button, Siri, Settings) brings back the call that
    /// runs, whichever Chief it is to, or calls the default Chief (``ChiefSources/primary``).
    /// - Returns: False when there is no OpenAI key for this account (the
    ///   caller opens Settings → Chief Calls).
    @discardableResult
    public func start(chief requested: ChiefSession? = nil) -> Bool {
        if let session, !session.hasEnded {
            if requested.map(isCalling) ?? true {
                isMinimized = false
                return true
            }
            session.hangUp()
            self.session = nil
            chief = nil
            toolbox = nil
        }
        let target = requested ?? sources.primary
        guard let store, let key = keys.key() else { return false }
        // One audio line at a time: a call ends voice mode.
        AgentVoiceMode.shared.stop()
        let toolbox = ChiefCallToolbox(chief: target, store: store, userName: userName)
        let config = VoiceCallSessionConfig(model: preferences.modelID, voice: preferences.voiceID,
                                            instructions: toolbox.briefing().instructions(now: Date()))
        let session = VoiceCallSession(link: makeLink(apiKey: key), toolbox: toolbox, config: config)
        session.onEnd = { [weak self, weak session] failure in
            guard let self, let session, self.session === session, self.isMinimized else { return }
            // Ended while minimized: a failure comes back on screen (what happened, Try Again);
            // a goodbye just closes, and the pill goes away.
            if failure != nil { self.isMinimized = false } else { self.close() }
        }
        self.session = session
        self.toolbox = toolbox
        chief = target
        chiefName = toolbox.chiefName
        chiefAvatar = target.avatar
        isMinimized = false
        seenChiefMessages = Set(target.store.messages.map(\.id))
        Task { [weak self] in
            guard await Self.microphoneAllowed() else {
                session.abort(.microphoneDenied)
                return
            }
            await session.start()
            self?.watchChief(for: session, toolbox: toolbox)
        }
        return true
    }

    /// The account signed out: hang up, close the screen, forget the account's key.
    public func signedOut() {
        configure(store: store ?? AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []), accountID: nil, userName: nil)
        isMinimized = false
    }

    /// Closes an ended call's screen, or hangs up and closes.
    public func close() {
        if let session, !session.hasEnded { session.hangUp() }
        session = nil
        chief = nil
        toolbox = nil
        isMinimized = false
    }

    /// Whether the running call is to `chief`, and still to the same Chief
    /// (the Cloud session can switch to another of the account's Chiefs).
    public func isCalling(_ chief: ChiefSession) -> Bool {
        guard let toolbox, self.chief === chief else { return false }
        return toolbox.isScoped
    }

    /// Tries an ended call again with the same settings, to the same Chief; when
    /// its session shows another Chief now, the call screen closes instead.
    public func retry() {
        let again = chief
        guard toolbox?.isScoped ?? true else {
            close()
            return
        }
        session = nil
        start(chief: again)
    }

    private func makeLink(apiKey: String) -> any VoiceCallLink {
        #if DEBUG
        if let script = ScriptedVoiceCallLink.requested() { return script }
        #endif
        return WebRTCVoiceCallLink(apiKey: apiKey, safetyIdentifier: accountID.map(Self.safetyIdentifier))
    }

    /// OpenAI's safety identifier: a hash of the cmux account, never the id.
    static func safetyIdentifier(_ accountID: String) -> String {
        SHA256.hash(data: Data("cmux-chief-call:\(accountID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Passes each new message of the called Chief to the call while it is
    /// live. Event driven: re-armed on every change of that Chief's last message.
    private func watchChief(for session: VoiceCallSession, toolbox: ChiefCallToolbox) {
        guard self.session === session, !session.hasEnded, let chief else { return }
        withObservationTracking {
            _ = chief.lastMessage
            _ = chief.identity
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session === session, !session.hasEnded else { return }
                self.passNewChiefMessages(to: session, toolbox: toolbox)
                self.watchChief(for: session, toolbox: toolbox)
            }
        }
    }

    private func passNewChiefMessages(to session: VoiceCallSession, toolbox: ChiefCallToolbox) {
        // The session shows another Chief now: its messages are not this call's.
        guard toolbox.isScoped, let chief else { return }
        let store = chief.store
        for message in store.messages where !seenChiefMessages.contains(message.id) {
            guard message.seq != nil else { continue }
            seenChiefMessages.insert(message.id)
            guard message.senderID != store.meID, !message.text.isEmpty, message.unsentAt == nil else { continue }
            // A long reply is cut for the ear; read_chief_messages has more.
            session.chiefReplied(String(message.text.prefix(2000)))
        }
    }
}
#endif
