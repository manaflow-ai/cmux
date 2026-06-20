public import Foundation

/// A terminal panel the ``TerminalTextSendCoordinator`` can deliver text to.
///
/// Abstracts the exact `TerminalPanel`/`TerminalSurface` operations the legacy
/// `AppDelegate.sendTextWhenReady` reached into, so the readiness orchestration
/// can move into the package without importing the app's terminal types. The
/// app-side conformer forwards each member to the underlying `TerminalPanel`.
@MainActor
public protocol TerminalTextSendPanel: AnyObject {
    /// Stable identity of the resolved panel, used only for DEBUG tracing parity.
    var panelID: UUID { get }

    /// True when the panel is an agent-hibernated surface. Mirrors
    /// `TerminalPanel.isAgentHibernated`: a hibernated panel accepts text
    /// immediately (it buffers into the recorder) without waiting for a live
    /// ghostty surface.
    var isAgentHibernated: Bool { get }

    /// True once the panel has a live ghostty surface. Mirrors
    /// `terminalPanel.surface.surface != nil`.
    var isSurfaceReady: Bool { get }

    /// Asks the panel's surface to start on input demand if it has not already.
    /// Mirrors `surface.requestInputDemandSurfaceStartIfNeeded()`.
    func requestInputDemandSurfaceStartIfNeeded()

    /// Delivers `text` to the panel, returning whether the send succeeded.
    /// Mirrors `terminalPanel.sendText(_:)`.
    @discardableResult
    func sendText(_ text: String) -> Bool
}
