public import OSLog

/// Emits dynamically enabled terminal-renderer intervals with negligible disabled-path work.
public struct TerminalRendererProfilingSignposts: Sendable {
    private let signposter = OSSignposter(
        subsystem: "com.cmux.terminal-renderer",
        category: .dynamicTracing
    )

    /// Creates a dynamic-tracing signpost emitter.
    public init() {}

    /// Whether a trace collector currently records dynamic signposts.
    @inline(__always)
    public var isEnabled: Bool { signposter.isEnabled }

    /// Starts one drawable-to-presentation frame interval.
    @inline(__always)
    public func beginFrame(
        _ metadata: @autoclosure () -> TerminalRendererProfilingMetadata
    ) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        let details = metadata().details
        return signposter.beginInterval(
            "terminal-renderer-frame",
            id: signposter.makeSignpostID(),
            "\(details, privacy: .public)"
        )
    }

    /// Ends a frame interval.
    @inline(__always)
    public func endFrame(
        _ state: OSSignpostIntervalState?,
        _ metadata: @autoclosure () -> TerminalRendererProfilingMetadata
    ) {
        guard let state else { return }
        let details = metadata().details
        signposter.endInterval("terminal-renderer-frame", state, "\(details, privacy: .public)")
    }

    /// Starts one coalesced renderer-update delivery interval.
    @inline(__always)
    public func beginUpdate(
        _ metadata: @autoclosure () -> TerminalRendererProfilingMetadata
    ) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        let details = metadata().details
        return signposter.beginInterval(
            "terminal-renderer-update",
            id: signposter.makeSignpostID(),
            "\(details, privacy: .public)"
        )
    }

    /// Ends a coalesced renderer-update delivery interval.
    @inline(__always)
    public func endUpdate(
        _ state: OSSignpostIntervalState?,
        _ metadata: @autoclosure () -> TerminalRendererProfilingMetadata
    ) {
        guard let state else { return }
        let details = metadata().details
        signposter.endInterval("terminal-renderer-update", state, "\(details, privacy: .public)")
    }
}
