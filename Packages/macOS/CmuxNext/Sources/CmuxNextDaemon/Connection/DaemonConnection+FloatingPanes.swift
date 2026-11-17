import Foundation

/// Floating panes (`floating-panes-v1`).
extension DaemonConnection {
    /// `float-pane`: floats `pane`, puts it back, or gives a floating pane `frame`. Needs
    /// `floating-panes-v1`; a daemon without it gets `missingCapabilities` and no request.
    @discardableResult
    public func floatPane(_ pane: PaneID, mode: FloatPaneRequest.Mode = .toggle, frame: FloatingPaneSnapshot.Frame? = nil,
                          transaction: UInt64? = nil) async throws -> FloatPaneRequest.Response {
        try await request(FloatPaneRequest(pane: pane, mode: mode, frame: frame, transaction: transaction))
    }
}
