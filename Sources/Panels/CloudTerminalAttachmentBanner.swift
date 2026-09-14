import Foundation

/// Text compatibility helper for attachment diagnostics.
///
/// The reconnect UI is rendered only by ``CloudTerminalOverlayCoordinator``.
/// Keeping this pure helper preserves localized diagnostic coverage without
/// creating a second SwiftUI presentation surface.
enum CloudTerminalAttachmentBanner {
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
