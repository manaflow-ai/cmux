#if os(iOS)
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileRealtime
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// The live Chief call, full screen: Chief's avatar ringed while it speaks,
/// who and how long, live captions with what Chief did ("Sent to Chief: …"),
/// and the call controls (Mute, Speaker, Keyboard, End). The chevron
/// minimizes the call to the shell's pill; it keeps running.
///
/// A tap on the avatar while Chief talks cuts it off, as speaking over it does.
public struct LiveCallScreen: View {
    let call: ChiefLiveCall
    let session: VoiceCallSession
    /// Opens Settings → Chief Calls (a refused key).
    let openKeySettings: () -> Void
    @State private var typing = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(call: ChiefLiveCall, session: VoiceCallSession, openKeySettings: @escaping () -> Void) {
        self.call = call
        self.session = session
        self.openKeySettings = openKeySettings
    }

    private var chiefName: String {
        let chief = ChiefSources.shared.primary
        let name = chief.title ?? chief.identity.title
        return name.isEmpty ? "Chief" : name
    }

    private var avatarText: String { ChiefSources.shared.primary.avatar }

    private var failure: VoiceCallFailure? {
        if case let .ended(failure) = session.phase { return failure }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            header
                .padding(.top, 8)
            if session.hasEnded, let failure {
                failureView(failure)
            } else {
                captions
            }
            if typing, session.isLive { composer }
            controls
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiveCallBackdrop().ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        // White controls on the dark call screen (no app accent on the chevron or buttons).
        .tint(.white)
        .onChange(of: statusLine) { _, line in
            AccessibilityNotification.Announcement(line).post()
        }
        .accessibilityIdentifier("chief.call")
    }

    // MARK: Top

    private var topBar: some View {
        HStack {
            if !session.hasEnded {
                Button {
                    call.isMinimized = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel(LiveCallText.minimize)
                .accessibilityIdentifier("chief.call.minimize")
            }
            Spacer()
            Label(VoiceCallModelChoice.all.first { $0.id == session.modelID }?.title ?? session.modelID,
                  systemImage: "waveform")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.08), in: .capsule)
                .accessibilityIdentifier("chief.call.model")
        }
        .frame(height: 44)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Button {
                session.interrupt()
            } label: {
                LiveCallAvatar(text: avatarText, speaking: session.chiefSpeaking, listening: session.userSpeaking,
                               reduceMotion: reduceMotion)
            }
            .buttonStyle(.plain)
            .disabled(!session.chiefSpeaking)
            .accessibilityLabel(chiefName)
            .accessibilityHint(session.chiefSpeaking ? LiveCallText.interruptHint : "")
            .accessibilityIdentifier("chief.call.avatar")
            Text(chiefName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Text(statusLine)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("chief.call.status")
                if let since = session.connectedAt {
                    Text(verbatim: "·").accessibilityHidden(true)
                    LiveCallElapsed(since: since, until: session.endedAt)
                        .accessibilityIdentifier("chief.call.elapsed")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .animation(theme.motion.smooth.animation, value: statusLine)
        }
    }

    private var statusLine: String {
        switch session.phase {
        case .connecting: return LiveCallText.connecting
        case .ended(nil): return LiveCallText.ended
        case .ended: return LiveCallText.failed
        case .live:
            if session.onHold { return LiveCallText.onHold }
            if session.userSpeaking { return LiveCallText.listening }
            if session.chiefSpeaking { return LiveCallText.speaking }
            if session.chiefThinking { return LiveCallText.thinking }
            if session.isMuted { return LiveCallText.muted }
            return LiveCallText.yourTurn
        }
    }

    // MARK: Captions

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.lines.isEmpty, session.isLive {
                        Text(LiveCallText.hint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 24)
                    }
                    ForEach(session.lines) { line in
                        LiveCallLineView(line: line)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            // The newest caption stays in view when the keyboard opens or closes.
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: session.lines.last?.text) { _, _ in
                withAnimation(theme.motion.smooth.animation) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: session.lines.count) { _, _ in
                withAnimation(theme.motion.smooth.animation) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .accessibilityIdentifier("chief.call.captions")
    }

    private func failureView(_ failure: VoiceCallFailure) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: failure.symbol)
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(failure.title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(failure.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("chief.call.failure")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bottom

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(LiveCallText.typePlaceholder, text: $draft, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($draftFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 20))
                .accessibilityIdentifier("chief.call.draft")
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, draft.isEmpty ? Color.gray.opacity(0.5) : Color.green)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(LiveCallText.send)
            .accessibilityIdentifier("chief.call.sendDraft")
        }
        .padding(.top, 8)
        .onAppear { draftFocused = true }
    }

    private func sendDraft() {
        session.send(text: draft)
        draft = ""
    }

    @ViewBuilder private var controls: some View {
        if session.hasEnded {
            HStack(spacing: 12) {
                if let failure, failure.retries {
                    Button(LiveCallText.tryAgain) { call.retry() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("chief.call.retry")
                }
                if let failure, failure.opensKeySettings {
                    Button(LiveCallText.openSettings) {
                        call.close()
                        openKeySettings()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chief.call.openSettings")
                } else if failure == .microphoneDenied {
                    Button(LiveCallText.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        call.close()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chief.call.openSettings")
                }
                Button(LiveCallText.done) { call.close() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
                    .accessibilityIdentifier("chief.call.done")
            }
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                LiveCallControl(symbol: session.isMuted ? "mic.slash.fill" : "mic.fill", title: LiveCallText.mute,
                                on: session.isMuted, identifier: "chief.call.mute") {
                    theme.haptics.selection()
                    session.setMuted(!session.isMuted)
                }
                LiveCallControl(symbol: "speaker.wave.2.fill", title: LiveCallText.speaker,
                                on: session.usesSpeaker, identifier: "chief.call.speaker") {
                    theme.haptics.selection()
                    session.setSpeaker(!session.usesSpeaker)
                }
                LiveCallControl(symbol: "keyboard", title: LiveCallText.keyboard, on: typing,
                                identifier: "chief.call.keyboard") {
                    withAnimation(theme.motion.snappy.animation) { typing.toggle() }
                }
                .disabled(!session.isLive)
                LiveCallControl(symbol: "phone.down.fill", title: LiveCallText.end, on: false, tint: .red,
                                identifier: "chief.call.end") {
                    session.hangUp()
                }
            }
        }
    }
}

/// Chief's avatar on the call: a breathing ring while Chief speaks, a
/// steady green ring while the user does. Still with Reduce Motion.
private struct LiveCallAvatar: View {
    let text: String
    let speaking: Bool
    let listening: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: !speaking || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let pulse = speaking && !reduceMotion ? (sin(phase * 5) + 1) / 2 : (speaking ? 1 : 0)
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(speaking ? 0.35 : 0), lineWidth: 3)
                    .frame(width: 128 + 22 * pulse, height: 128 + 22 * pulse)
                Circle()
                    .stroke(Color.green.opacity(listening ? 0.9 : 0), lineWidth: 3)
                    .frame(width: 136, height: 136)
                Text(String(text.prefix(2)))
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 120, height: 120)
                    .background(Circle().fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.26)],
                                                             startPoint: .top, endPoint: .bottom)))
            }
            .frame(width: 160, height: 160)
        }
        .animation(theme.motion.smooth.animation, value: listening)
        .animation(theme.motion.smooth.animation, value: speaking)
    }
}

private struct LiveCallElapsed: View {
    let since: Date
    let until: Date?

    var body: some View {
        if let until {
            Text(Duration.seconds(max(0, until.timeIntervalSince(since))), format: .time(pattern: .minuteSecond))
                .monospacedDigit()
        } else {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
            }
        }
    }
}

private struct LiveCallLineView: View {
    let line: VoiceCallLine

    var body: some View {
        switch line.role {
        case .you:
            HStack {
                Spacer(minLength: 48)
                Text(line.text.isEmpty ? "…" : line.text)
                    .font(.body)
                    .foregroundStyle(.white.opacity(line.isFinal ? 0.75 : 0.5))
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityLabel(LiveCallText.you + ": " + line.text)
        case .chief:
            Text(line.text)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(line.isFinal ? 1 : 0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity:
            Label(line.text, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.green)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.green.opacity(0.14), in: .capsule)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chief.call.activity")
        }
    }
}

private struct LiveCallControl: View {
    let symbol: String
    let title: String
    let on: Bool
    var tint: Color?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint != nil ? .white : (on ? .black : .white))
                    .frame(width: 68, height: 68)
                    .background(Circle().fill(tint ?? (on ? .white : .white.opacity(0.16))))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(tint == nil ? (on ? Text(LiveCallText.on) : Text(LiveCallText.off)) : Text(verbatim: ""))
        .accessibilityIdentifier(identifier)
    }
}

/// The call's backdrop: near-black with a soft glow, light or dark mode alike.
private struct LiveCallBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
            RadialGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.3).opacity(0.9), .clear],
                           center: .init(x: 0.5, y: 0.18), startRadius: 10, endRadius: 420)
        }
    }
}

/// The running call while minimized: a green pill over the app, tap to go back.
public struct LiveCallPill: View {
    let call: ChiefLiveCall
    let session: VoiceCallSession

    public init(call: ChiefLiveCall, session: VoiceCallSession) {
        self.call = call
        self.session = session
    }

    public var body: some View {
        Button {
            call.isMinimized = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: session.chiefSpeaking ? "waveform" : "phone.fill")
                    .symbolEffect(.variableColor.iterative, isActive: session.chiefSpeaking)
                Text(LiveCallText.pillTitle)
                    .fontWeight(.semibold)
                if let since = session.connectedAt {
                    LiveCallElapsed(since: since, until: session.endedAt)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.green, in: .capsule)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LiveCallText.pillAccessibility)
        .accessibilityIdentifier("chief.call.pill")
    }
}

extension VoiceCallFailure {
    var symbol: String {
        switch self {
        case .microphoneDenied: "mic.slash"
        case .keyMissing, .keyRejected: "key"
        case .quota: "creditcard"
        case .network, .dropped: "wifi.exclamationmark"
        case .modelUnavailable, .refused: "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .microphoneDenied: LiveCallText.failMicrophone
        case .keyMissing: LiveCallText.failKeyMissing
        case .keyRejected: LiveCallText.failKeyRejected
        case .quota: LiveCallText.failQuota
        case .modelUnavailable: LiveCallText.failModel
        case .refused: LiveCallText.failRefused
        case .network: LiveCallText.failNetwork
        case .dropped: LiveCallText.failDropped
        }
    }

    var detail: String {
        switch self {
        case .microphoneDenied: LiveCallText.failMicrophoneDetail
        case .keyMissing, .keyRejected: LiveCallText.failKeyDetail
        case let .quota(message), let .modelUnavailable(message), let .refused(message), let .network(message): message
        case .dropped: LiveCallText.failDroppedDetail
        }
    }

    var retries: Bool {
        switch self {
        case .network, .dropped, .refused, .quota: true
        case .microphoneDenied, .keyMissing, .keyRejected, .modelUnavailable: false
        }
    }

    var opensKeySettings: Bool {
        switch self {
        case .keyMissing, .keyRejected, .modelUnavailable: true
        default: false
        }
    }
}
#endif
