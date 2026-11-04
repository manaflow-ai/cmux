#if os(iOS)
import AVFoundation
public import CmuxMobileRealtime
import CryptoKit
import Foundation
import Observation

/// Voice mode, the app's one: a live GPT Realtime line to one agent
/// session (a GUI chat or a terminal agent). The agent's new words are
/// read aloud near verbatim (code, diffs and tool noise left out, see
/// ``AgentVoiceSpeech``) and what the user says goes to the agent as a
/// prompt. It uses the OpenAI key and voice of Settings → Chief Calls; with
/// no key, ``openKeySettings`` sends the user there.
@MainActor
@Observable
public final class AgentVoiceMode {
    public static let shared = AgentVoiceMode()

    /// The running (or just failed) voice mode; nil when off.
    public private(set) var session: AgentVoiceSession?
    /// Opens Settings → Chief Calls (set by the shell).
    @ObservationIgnored public var openKeySettings: (@MainActor () -> Void)?
    /// Ends a Chief call before voice mode takes the microphone (set by the shell).
    @ObservationIgnored public var endOtherAudio: (@MainActor () -> Void)?

    @ObservationIgnored private let keys: OpenAIKeyModel
    @ObservationIgnored private let preferences: VoiceCallPreferences
    @ObservationIgnored private let launcher: AgentVoiceLauncher
    /// The session voice mode talks to; released on stop, so a closed chat's
    /// store is not kept alive (a failed run keeps it for Try Again).
    @ObservationIgnored private var source: (any AgentVoiceSource)?
    @ObservationIgnored private var feed: AgentVoiceFeed?
    @ObservationIgnored private var accountID: String?

    public init(keys: OpenAIKeyModel = .shared, preferences: VoiceCallPreferences = .shared,
                launcher: AgentVoiceLauncher = .shared) {
        self.keys = keys
        self.preferences = preferences
        self.launcher = launcher
    }

    /// Installs the composer buttons' path for the signed-in account; nil
    /// (signed out) ends voice mode and removes the buttons.
    public func install(accountID: String?) {
        if accountID != self.accountID { stop() }
        self.accountID = accountID
        if accountID == nil {
            launcher.handler = nil
        } else {
            launcher.handler = { [weak self] (source: any AgentVoiceSource) in self?.toggle(source) }
        }
    }

    /// Starts voice mode on `source`, or ends it when it already runs there.
    public func toggle(_ source: any AgentVoiceSource) {
        if launcher.activeSourceID == source.voiceSourceID, let session, !session.hasEnded {
            stop()
            return
        }
        stop()
        let demo = Self.scriptedLink()
        guard demo != nil || keys.key() != nil else {
            openKeySettings?()
            return
        }
        endOtherAudio?()
        let config = AgentVoiceSessionConfig(model: preferences.modelID, voice: preferences.voiceID,
                                             agentName: source.voiceAgentName)
        let link: any VoiceCallLink = demo ?? WebRTCVoiceCallLink(
            apiKey: keys.key() ?? "", safetyIdentifier: accountID.map(Self.safetyIdentifier))
        let session = AgentVoiceSession(link: link, config: config)
        session.onUserSaid = { [weak source, weak session] text in
            // Not sent (the Mac is offline, a permission is open): say why, never retry it later.
            guard let source else {
                session?.relay(AgentVoiceText.sessionGone)
                return
            }
            if let refusal = source.sendVoicePrompt(text) { session?.relay(refusal) }
        }
        session.onEnd = { [weak self, weak session] failure in
            guard let self, let session, self.session === session else { return }
            self.feed?.cancel()
            self.feed = nil
            self.launcher.activeSourceID = nil
            // A failure stays on the bar (what happened, Settings or Try Again); a clean end closes it.
            if failure == nil {
                self.session = nil
                self.source = nil
            }
        }
        self.source = source
        self.session = session
        launcher.activeSourceID = source.voiceSourceID
        feed = source.startVoiceFeed { [weak session] text in session?.relay(text) }
        Task {
            let allowed = demo != nil ? true : await Self.microphoneAllowed()
            guard allowed else {
                session.abort(.microphoneDenied)
                return
            }
            await session.start()
        }
    }

    /// Ends voice mode and closes its bar.
    public func stop() {
        feed?.cancel()
        feed = nil
        source = nil
        let session = session
        self.session = nil
        session?.end()
        launcher.activeSourceID = nil
    }

    /// Starts again on the same session after a failure.
    public func retry() {
        guard let source else { return }
        stop()
        toggle(source)
    }

    /// The agent the bar names.
    public var agentName: String? { session?.agentName }

    private static func scriptedLink() -> (any VoiceCallLink)? {
        #if DEBUG
        return ScriptedAgentVoiceLink.requested()
        #else
        return nil
        #endif
    }

    /// OpenAI's safety identifier: a hash of the cmux account, never the id.
    static func safetyIdentifier(_ accountID: String) -> String {
        SHA256.hash(data: Data("cmux-voice-mode:\(accountID)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }
}
#endif
