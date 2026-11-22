#if DEBUG
import Foundation
#if os(iOS)
import OSLog
import QuartzCore
#endif

/// DEBUG model of what the Mac does to the phone while the person types
/// (`CMUX_MOBILE_HOST_LOAD=idle|heavy|cut`, `ComposerKeyToGlyphUITests`). The
/// mock has no link, so the Mac's CPU or connection reaches the phone only
/// as what it sends, and this replays that:
///
/// - `idle`: nothing (the default, also when unset);
/// - `heavy`: a busy Mac's pushes, from the first keyboard on. The shell's
///   driver (`HostLoadDriver`) updates workspace rows at 20 Hz (8 rows each) and replaces every Mac's
///   tree once a second, as `onRows` and `onTree` do; and it posts `tick`,
///   on which the mock terminal writes a status line (output, as a streaming
///   build does) and the mock chat re-sends its status (as the daemon's
///   status events do). Once a second ten pushes land in one main-queue turn,
///   a slow Mac's backlog arriving at once;
/// - `cut`: the link drops at launch (`cut`): the terminal goes offline, the
///   chat disconnected, and nothing more arrives.
public enum HostLoadSim {
    public enum Mode: String, Sendable {
        case idle, heavy, cut
    }

    public static let mode: Mode = {
        let env = ProcessInfo.processInfo.environment["CMUX_MOBILE_HOST_LOAD"] ?? ""
        return Mode(rawValue: env) ?? .idle
    }()

    /// One heavy tick (object: its count, an `Int`).
    public static let tick = Notification.Name("dev.cmux.mobile.host-load.tick")
    /// The link drops.
    public static let cut = Notification.Name("dev.cmux.mobile.host-load.cut")
}
/// Where the heavy load's main-thread time goes (DEBUG): each push apply is a
/// signpost interval (`dev.cmux.mobile`, category `composer`; `push_apply_rows`,
/// `push_apply_tree`, `push_apply_status`, `push_apply_chat`, the whole ten-push
/// turn `push_burst_sync`) and, with `InputLatencyTrace` on, a sample of its ms.
/// The run-loop iteration that held a push turn is sampled whole
/// (`push_burst_iteration`, `push_tick_iteration`, up to before-waiting), from the
/// turn to after Core Animation's commit (`push_burst_turn`, `push_tick_turn`: the
/// SwiftUI updates and layout it queued), and the burst's start to the next
/// presented frame as `push_burst_to_frame`. Samples skip the board
/// (its summary re-sort is main-thread time too); the next key's sample shows them.
@MainActor
public enum PushApplyTrace {
    #if os(iOS)
    static let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "composer")
    #endif

    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        #if os(iOS)
        let trace = InputLatencyTrace.shared
        guard trace != nil || signposter.isEnabled else { return try body() }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        let start = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - start) * 1000
            signposter.endInterval(name, state)
            trace?.quietSample("\(name)", ms: ms)
        }
        #endif
        return try body()
    }

    /// Samples the run-loop iteration running now, whole, as `kind` when it ends.
    public static func tagIteration(_ kind: String) {
        #if os(iOS)
        InputLatencyTrace.shared?.tagIteration(kind)
        #endif
    }

    /// Samples from now to the next presented frame as `kind`.
    public static func toNextFrame(_ kind: String) {
        #if os(iOS)
        InputLatencyTrace.shared?.quietSampleAtNextFrame(kind, since: CACurrentMediaTime())
        #endif
    }
}
#endif
