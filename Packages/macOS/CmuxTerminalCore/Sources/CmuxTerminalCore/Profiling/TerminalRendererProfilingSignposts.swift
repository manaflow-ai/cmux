internal import Foundation
public import OSLog

/// Emits terminal-renderer points of interest with negligible disabled-path work.
public struct TerminalRendererProfilingSignposts: Sendable {
    private let signposter: OSSignposter
    private let collectionRequested: Bool

    private static let defaultCollectionRequested: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["CMUX_TERMINAL_RENDERER_PROFILING"] == "1" ||
            environment["CMUX_KEY_LATENCY_PROBE"] == "1"
    }()

    /// Creates a points-of-interest signpost emitter captured by standard Instruments templates.
    /// Collection is opt-in through `CMUX_TERMINAL_RENDERER_PROFILING=1` or the existing
    /// `CMUX_KEY_LATENCY_PROBE=1` profiling mode so ordinary rendering retains its disabled path.
    public init() {
        self.init(
            signposter: OSSignposter(
                subsystem: "com.cmux.terminal-renderer",
                category: .pointsOfInterest
            ),
            collectionRequested: Self.defaultCollectionRequested
        )
    }

    init(signposter: OSSignposter, collectionRequested: Bool) {
        self.signposter = signposter
        self.collectionRequested = collectionRequested
    }

    /// Whether a trace collector currently records points-of-interest signposts.
    @inline(__always)
    public var isEnabled: Bool { collectionRequested && signposter.isEnabled }

    /// Starts one drawable-to-presentation frame interval.
    @inline(__always)
    public func beginFrame(
        _ metadata: @autoclosure () -> TerminalRendererProfilingMetadata
    ) -> OSSignpostIntervalState? {
        guard isEnabled else { return nil }
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
        guard isEnabled else { return nil }
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
