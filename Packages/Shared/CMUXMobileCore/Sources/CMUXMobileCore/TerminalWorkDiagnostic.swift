import Foundation

/// Correlation and phase metadata for one terminal operation, with no content.
public struct TerminalWorkDiagnostic: Sendable, Codable, Equatable {
    /// Stable names for potentially blocking boundaries on both platforms.
    public enum Phase: String, Sendable, Codable, CaseIterable {
        /// AppKit or UIKit layout, including constraint resolution.
        case layout
        /// Applying a pane topology or geometry snapshot.
        case geometryPublication
        /// Waiting for the mobile surface's serial geometry queue.
        case geometryQueue
        /// Calling Ghostty's size API, which publishes renderer and PTY resize work.
        /// Completion means the API returned, not that the PTY consumed SIGWINCH.
        case resizePublication
        /// Requesting a renderer refresh or presentation.
        case rendererRefresh
        /// Delivering a manual-I/O terminal's PTY resize request.
        case ptyResizeRequest
        /// Applying a mobile render-grid replay to Ghostty.
        case renderGridReplay
    }

    /// Ephemeral operation identity, used only to pair begin and end records.
    public let operationID: UUID
    /// The boundary being measured.
    public let phase: Phase
    /// Owner population and originating transition captured before dispatch.
    public let context: TerminalWorkContext
    /// Whether the operation began on the main thread.
    public let onMainThread: Bool

    /// Creates the content-free metadata for an operation.
    /// - Parameters:
    ///   - operationID: An ephemeral ID, never a surface or workspace ID.
    ///   - phase: The measured boundary.
    ///   - context: The immutable owner snapshot.
    ///   - onMainThread: Whether this phase runs on the main thread.
    public init(
        operationID: UUID,
        phase: Phase,
        context: TerminalWorkContext,
        onMainThread: Bool
    ) {
        self.operationID = operationID
        self.phase = phase
        self.context = context
        self.onMainThread = onMainThread
    }
}
