#if os(iOS)
import Darwin
import Foundation
import Observation
import OSLog
import QuartzCore
import SwiftUI

/// Launch to first interaction, step by step: each mark is taken once per
/// process, in milliseconds since the process started (the kernel's start time,
/// so dyld and static initializers count). Every build emits a signpost per mark
/// (subsystem `dev.cmux.mobile`, category `launch`) for Instruments, and logs
/// `timing launch <mark> (<ms>)` under the `timing` category, next to
/// `ConnectTimeline`'s connect steps.
///
/// The marks (cmux-next-ios/design/launch-tti.md):
/// - `app_init`: the App's `init` began (dyld, static initializers and UIKit's start before it)
/// - `first_frame`: the first SwiftUI frame (the launch mark) was presented
/// - `shell_frame`: the signed-in shell's first frame was presented
/// - `workspaces_list_frame`: the Workspaces list's first frame with rows was presented (the list rig's seeded rows)
/// - `workspace_row_tap`: a workspace row was tapped
/// - `chat_composer_ready`: an agent chat's composer was on screen (first frame presented; not a hidden chat face)
/// - `terminal_ready`: a terminal attached to its session presented a frame
/// - `terminal_key_sent`: the first single printable key a terminal's session accepted
/// - `terminal_echo_presented`: that key's byte, as text in that terminal's output, was presented
///
/// Cost is constant: a fixed set of names, each taken once; the one-shot
/// display link of `markNextFrame` stops at its first frame.
///
/// DEBUG builds with `CMUX_MOBILE_LAUNCH_MARKS=1` also show the marks as one
/// JSON object in a nearly transparent label, `debug.launch-marks` (its
/// accessibility value), which `LaunchTTIUITests` reads.
@MainActor
public final class LaunchMarks {
    public static let shared = LaunchMarks()

    private init() {}

    private static let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "launch")
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "timing")

    /// The marks taken so far, in order, in ms since the process started.
    public private(set) var marks: [(name: String, ms: Double)] = []
    private var pending: Set<String> = []

    /// Whether `name` has been taken in this process.
    public func has(_ name: String) -> Bool { marks.contains { $0.name == name } }

    /// Takes `name` now, once per process.
    public func mark(_ name: String) {
        guard !has(name) else { return }
        let ms = Date().timeIntervalSince(Self.processStart) * 1000
        marks.append((name, ms))
        Self.signposter.emitEvent("mark", "\(name, privacy: .public)")
        Self.log.info("timing launch \(name, privacy: .public) (\(Int(ms.rounded()), privacy: .public)ms)")
        #if DEBUG
        LaunchMarksBoard.shared?.update()
        #endif
    }

    /// Takes `name` when the next frame is presented (a one-shot display link),
    /// once per process: the frame that shows what was just laid out.
    public func markNextFrame(_ name: String) {
        guard !has(name), pending.insert(name).inserted else { return }
        OneFrame.after { [self] in pending.remove(name); mark(name) }
    }

    /// When this process started, from the kernel (falls back to the first read).
    public static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// The marks as one JSON object, `{"mark": ms, ...}`.
    public var json: String {
        "{" + marks.map { String(format: "\"%@\":%.1f", $0.name, $0.ms) }.joined(separator: ",") + "}"
    }
}

/// A display link that fires once, at the next frame, then stops.
@MainActor
private final class OneFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?
    private static var live: Set<OneFrame> = []

    static func after(_ action: @escaping () -> Void) {
        let frame = OneFrame()
        frame.action = action
        let link = CADisplayLink(target: frame, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        frame.link = link
        live.insert(frame)
    }

    @objc private func step() {
        link?.invalidate()
        link = nil
        Self.live.remove(self)
        let action = action
        self.action = nil
        action?()
    }
}

#if DEBUG
/// The marks for a UI test to read (`CMUX_MOBILE_LAUNCH_MARKS=1`, DEBUG only).
@MainActor
@Observable
public final class LaunchMarksBoard {
    public static let shared: LaunchMarksBoard? =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_LAUNCH_MARKS"] == "1" ? LaunchMarksBoard() : nil

    public private(set) var text = "{}"

    func update() { text = LaunchMarks.shared.json }
}

/// The board as a nearly transparent label (`debug.launch-marks`), over the app's root.
public struct LaunchMarksProbe: View {
    public init() {}

    public var body: some View {
        if let board = LaunchMarksBoard.shared {
            Text(board.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.launch-marks")
                .accessibilityLabel(board.text)
        }
    }
}
#endif
#endif
