#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// What `--record-launch DIR [--record-launch-seconds S]` asks for (CmuxNextApp's `DebugWindowRecord`): every
/// window recorded from the moment it is made, for S seconds (6 by default, at most 12), into `DIR/window-N`.
/// nil without the argument or its folder.
public struct LaunchRecordRequest: Equatable, Sendable {
    public let dir: String
    public let seconds: Double

    public init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--record-launch"), flag + 1 < arguments.count,
              !arguments[flag + 1].hasPrefix("--") else { return nil }
        dir = (arguments[flag + 1] as NSString).expandingTildeInPath
        let asked = arguments.firstIndex(of: "--record-launch-seconds").flatMap { index in
            index + 1 < arguments.count ? Double(arguments[index + 1]) : nil
        }
        seconds = min(12, max(0.1, asked ?? 6))
    }
}
#endif
