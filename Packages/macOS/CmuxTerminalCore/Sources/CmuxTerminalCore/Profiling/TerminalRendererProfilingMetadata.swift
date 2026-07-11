import Foundation

/// A closed set of renderer state that is safe to publish in profiling traces.
public struct TerminalRendererProfilingMetadata: Equatable, Sendable {
    /// Opaque cmux workspace and surface identifiers.
    public let identity: TerminalRendererProfilingIdentity
    /// Whether cmux considers the surface visible.
    public let visible: Bool
    /// Whether cmux considers the surface focused.
    public let focused: Bool
    /// The typed source that most recently requested renderer work.
    public let wakeReason: TerminalRendererProfilingWakeReason
    /// The number of renderer notifications combined into this update.
    public let coalescedUpdateCount: Int
    /// Exact dirty rows when the renderer exposes them, otherwise `nil`.
    public let dirtyRowCount: Int?
    /// Exact full-redraw state when the renderer exposes it, otherwise `nil`.
    public let fullRedraw: Bool?

    /// Creates a privacy-closed renderer profiling payload.
    public init(
        identity: TerminalRendererProfilingIdentity,
        visible: Bool,
        focused: Bool,
        wakeReason: TerminalRendererProfilingWakeReason,
        coalescedUpdateCount: Int,
        dirtyRowCount: Int?,
        fullRedraw: Bool?
    ) {
        self.identity = identity
        self.visible = visible
        self.focused = focused
        self.wakeReason = wakeReason
        self.coalescedUpdateCount = coalescedUpdateCount
        self.dirtyRowCount = dirtyRowCount
        self.fullRedraw = fullRedraw
    }

    /// The public trace payload. No API input can contain terminal text, commands, paths, or environment values.
    public var details: String {
        let dirtyRows = dirtyRowCount.map(String.init) ?? "unknown"
        let redraw = fullRedraw.map { $0 ? "1" : "0" } ?? "unknown"
        var details = String()
        details.reserveCapacity(200)
        details.append("workspace=")
        details.append(identity.workspaceId.uuidString)
        details.append(" surface=")
        details.append(identity.surfaceId.uuidString)
        details.append(" visible=")
        details.append(visible ? "1" : "0")
        details.append(" focused=")
        details.append(focused ? "1" : "0")
        details.append(" wake=")
        details.append(wakeReason.rawValue)
        details.append(" coalesced=")
        details.append(String(coalescedUpdateCount))
        details.append(" dirty_rows=")
        details.append(dirtyRows)
        details.append(" full_redraw=")
        details.append(redraw)
        return details
    }
}
