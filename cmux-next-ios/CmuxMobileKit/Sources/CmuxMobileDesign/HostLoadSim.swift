#if DEBUG
import Foundation

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
#endif
