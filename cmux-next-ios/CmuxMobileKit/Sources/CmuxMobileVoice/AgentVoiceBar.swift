#if os(iOS)
import CmuxMobileDesign
import CmuxMobileRealtime
import SwiftUI

/// Voice mode's strings beyond the call screen's (Resources/Localizable.xcstrings).
// lint:allow namespace: the module's string table; each member is a catalog lookup with no owning type.
enum AgentVoiceText {
    static func title(_ agent: String) -> String {
        String(format: String(localized: "voiceMode.title", defaultValue: "Voice · %@", bundle: .module), agent)
    }
    static var idle: String { String(localized: "voiceMode.status.idle", defaultValue: "Reading new replies aloud", bundle: .module) }
    static var end: String { String(localized: "voiceMode.button.end", defaultValue: "End Voice Mode", bundle: .module) }
    static var sessionGone: String { String(localized: "voiceMode.notSent.gone", defaultValue: "Not sent: this session is closed.", bundle: .module) }
    static var unmute: String { String(localized: "voiceMode.button.unmute", defaultValue: "Unmute", bundle: .module) }
}

/// Voice mode's bar, over the top of the app while it runs: who it talks
/// to, what it hears or says now (live captions), mute, and end. A tap on
/// the captions while the agent's words play skips the rest of them.
public struct AgentVoiceBar: View {
    let mode: AgentVoiceMode
    let session: AgentVoiceSession

    public init(mode: AgentVoiceMode, session: AgentVoiceSession) {
        self.mode = mode
        self.session = session
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentVoiceText.title(session.agentName))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("voiceMode.caption")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { if session.agentSpeaking { session.skip() } }
            controls
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceMode.bar")
    }

    @ViewBuilder private var indicator: some View {
        Group {
            if case .connecting = session.phase {
                ProgressView().controlSize(.small)
            } else if let failure = session.failure {
                Image(systemName: failure.symbol).foregroundStyle(.red)
            } else if session.isMuted {
                Image(systemName: "mic.slash.fill").foregroundStyle(.secondary)
            } else if session.userSpeaking {
                Image(systemName: "mic.fill").foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: true)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(session.agentSpeaking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .symbolEffect(.variableColor.iterative, isActive: session.agentSpeaking)
            }
        }
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 28, height: 28)
    }

    /// The newest caption while someone talks; otherwise the state.
    private var detail: String {
        if case .connecting = session.phase { return LiveCallText.connecting }
        if let failure = session.failure { return failure.title }
        if let line = session.lines.last, !line.text.isEmpty, !line.isFinal || session.agentSpeaking || session.userSpeaking {
            return line.text
        }
        if session.isMuted { return LiveCallText.muted }
        return AgentVoiceText.idle
    }

    @ViewBuilder private var controls: some View {
        if let failure = session.failure {
            if failure.opensKeySettings {
                Button(LiveCallText.openSettings) {
                    mode.stop()
                    mode.openKeySettings?()
                }
                .buttonStyle(.glass)
            } else if failure.retries {
                Button(LiveCallText.tryAgain) { mode.retry() }
                    .buttonStyle(.glass)
            }
            closeButton
        } else {
            Button {
                session.setMuted(!session.isMuted)
            } label: {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(session.isMuted ? Color.cmuxMobileAccent.opacity(0.18) : Color.cmuxMobileFill, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isMuted ? AgentVoiceText.unmute : LiveCallText.mute)
            .accessibilityIdentifier("voiceMode.mute")
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            mode.stop()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.red, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AgentVoiceText.end)
        .accessibilityIdentifier("voiceMode.end")
    }
}
#endif
