import SwiftUI

/// A small pill over a native cloud pane while its attachment is not live.
///
/// The last screen stays visible underneath; the banner only says what the
/// session is doing about it. It waits a moment before appearing so the normal
/// sub-second attach never flashes it.
struct CloudTerminalAttachmentBanner: View {
    let status: CloudTerminalAttachmentStatus?
    @State private var visible = false

    var body: some View {
        if let status, let text = Self.text(for: status.state, machineID: status.machineID) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .opacity(visible ? 1 : 0)
            .animation(.easeIn(duration: 0.15).delay(1), value: visible)
            .allowsHitTesting(false)
            .accessibilityIdentifier("cloud-attachment-banner")
            // Visual timing only; removing the banner cancels its presentation.
            .onAppear { visible = true }
            .onDisappear { visible = false }
        }
    }

    static func text(for state: CloudTerminalAttachmentState, machineID: String) -> String? {
        switch state {
        case .attached, .ended:
            return nil
        case let .attaching(attempt):
            let format = attempt > 1
                ? String(localized: "cloudPane.attachment.attachingAgain", defaultValue: "Attaching to %@… (attempt %lld)")
                : String(localized: "cloudPane.attachment.attaching", defaultValue: "Attaching to %@…")
            return attempt > 1 ? String(format: format, machineID, Int64(attempt)) : String(format: format, machineID)
        case let .reconnecting(attempt, reason):
            return String(
                format: String(
                    localized: "cloudPane.attachment.reconnecting",
                    defaultValue: "Reconnecting to %@… (attempt %lld; %@)"
                ),
                machineID,
                Int64(attempt),
                reason.localizedDescription
            )
        }
    }
}
