#if os(iOS)
import CmuxChiefVoiceCore
import SwiftUI
import UIKit

/// The full-screen Chief call: who, how long, what is happening, and End.
///
/// Renders ``ChiefVoiceController/coordinator``'s state. End stops the
/// recording; Done (or Open Settings when the microphone is off) closes the
/// screen once the note is sent or saved. VoiceOver reads each new state line.
public struct ChiefCallScreen: View {
    let controller: ChiefVoiceController

    /// Creates the screen over `controller`.
    public init(controller: ChiefVoiceController) {
        self.controller = controller
    }

    private var state: ChiefCallState { controller.state }

    private var name: String {
        let name = controller.chiefName ?? ""
        return name.isEmpty ? VoiceText.callTitle : name
    }

    private var title: String {
        controller.presented == .voiceNote ? VoiceText.voiceNoteTitle : name
    }

    private var status: String {
        switch state {
        case .idle, .requestingPermission: VoiceText.askingMicrophone
        case .permissionDenied: VoiceText.microphoneDenied
        case .recording: VoiceText.recording
        case .finishing: VoiceText.saving
        case .transcribing: VoiceText.transcribing
        case .sending: VoiceText.sending
        case .sent: VoiceText.sent
        case .savedForLater: VoiceText.savedForLater
        case .failed: VoiceText.failed
        }
    }

    private var recordingSince: Date? {
        if case let .recording(_, startedAt) = state { return startedAt }
        return nil
    }

    private var finished: Bool {
        switch state {
        case .permissionDenied, .sent, .savedForLater, .failed: true
        default: false
        }
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 44, weight: .semibold))
                .frame(width: 112, height: 112)
                .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                .accessibilityHidden(true)
                .padding(.bottom, 8)
            Text(title)
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            elapsed
            Text(status)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            if recordingSince != nil {
                Button {
                    Task { await controller.end() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(.red))
                }
                .accessibilityLabel(VoiceText.endButton)
                .accessibilityIdentifier("chief-call-end")
            } else if finished {
                Button(state == .permissionDenied ? VoiceText.openSettingsButton : VoiceText.doneButton) {
                    if state == .permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    controller.dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("chief-call-done")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 72)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onChange(of: status) { _, line in
            AccessibilityNotification.Announcement(line).post()
        }
    }

    /// The elapsed time while recording; TimelineView redraws it once a second.
    @ViewBuilder private var elapsed: some View {
        if let start = recordingSince {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(start))),
                     format: .time(pattern: .minuteSecond))
                    .font(.system(size: 20).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
