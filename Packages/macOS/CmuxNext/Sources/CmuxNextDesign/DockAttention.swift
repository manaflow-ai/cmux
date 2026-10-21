public import AppKit

/// The Dock icon's bounce (`notifications.dockBounce`, mapped by the App), one request at a
/// time. A bounce that lasts until the user switches to cmux also ends once
/// nothing is unread any more (read on the phone, from the CLI, or by Mark All
/// Read), so an alert that was dealt with elsewhere never keeps bouncing.
@MainActor
public final class DockAttention {
    private var request: Int?

    public init() {}

    /// Bounces for an alert that arrived while cmux was inactive: once, or until the user switches to cmux.
    public func bounce(untilActive: Bool) {
        guard !NSApp.isActive else { return }
        cancel()
        let id = NSApp.requestUserAttention(untilActive ? .criticalRequest : .informationalRequest)
        request = untilActive ? id : nil
    }

    /// The unread count changed; at zero a bounce still running ends.
    public func unreadChanged(_ count: Int) {
        if count == 0 { cancel() }
    }

    private func cancel() {
        if let request { NSApp.cancelUserAttentionRequest(request) }
        request = nil
    }
}
