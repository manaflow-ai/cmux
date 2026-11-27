import Foundation
import Observation

/// Pane-owned, in-memory connection notice. Dismissal lasts until this attachment recovers.
@MainActor
@Observable
final class DeviceTerminalAttachmentStatus {
    private(set) var isConnected = false
    private(set) var isConnecting = true
    private(set) var isDismissed = false
    private var hasDisconnected = false
    @ObservationIgnored var onRetry: (() -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?

    func update(connected: Bool, connecting: Bool) {
        guard isConnected != connected || isConnecting != connecting else { return }
        isConnected = connected
        isConnecting = connecting
        if connected {
            isDismissed = false
            hasDisconnected = false
        } else if !connecting {
            hasDisconnected = true
        }
        onChange?()
    }

    func dismiss() {
        isDismissed = true
        onChange?()
    }

    func retry() {
        isDismissed = false
        isConnecting = true
        onRetry?()
        onChange?()
    }

    var presentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        guard !isConnected, !isDismissed, hasDisconnected else { return nil }
        return .init(
            title: String(localized: "devices.terminal.disconnected.title", defaultValue: "Mac disconnected"),
            detail: String(localized: "devices.terminal.disconnected.detail", defaultValue: "Your layout and scrollback are preserved. Retry when the other Mac is available."),
            showsProgress: isConnecting,
            showsReconnectButton: true
        )
    }
}
