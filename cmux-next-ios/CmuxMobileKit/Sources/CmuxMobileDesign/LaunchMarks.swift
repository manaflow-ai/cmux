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
/// - `main`: the process's entry ran (dyld and static initializers before it)
/// - `app_init`: the App's `init` began (UIKit's start before it, after `main`)
/// - `init_hang_watch`, `init_classic_leftovers`, `init_legacy_storage`, `init_read_first`,
///   `init_auth`, `app_init_done`: each of the App's `init` steps ended
/// - `did_finish_launching`, `did_finish_launching_done`: the app delegate's launch began and ended
/// - `first_frame`: the first SwiftUI frame (the launch mark) was presented
/// - `shell_frame`: the signed-in shell's first frame was presented
/// - `workspaces_list_frame`: the Workspaces list's first frame with rows was presented (the list rig's seeded rows)
/// - `workspace_row_tap`: a workspace row was tapped
/// - `chat_composer_ready`: an agent chat's composer was on screen (first frame presented; not a hidden chat face)
/// - `chat_first_row_frame`: the first readable transcript row was laid out and presented
/// - `terminal_ready`: a terminal attached to its session presented a frame
/// - `terminal_first_row_frame`: the first non-empty terminal output row was presented
/// - `terminal_key_sent`: the first single printable key a terminal's session accepted
/// - `terminal_echo_presented`: that key's byte, as text in that terminal's output, was presented
/// - `demo_done` (DEBUG): a `-cmux-mobile-demo` driver finished and its last state stopped moving
/// - `shell_still` (DEBUG, with the board): the shell's first state stopped moving
/// - `list_hold` (DEBUG): the list stress rig (`CMUX_MOBILE_LIST_PASSES=0`) holds its screen, still
///
/// Cost is constant: a fixed set of names, each taken once; the one-shot
/// display link of `markNextFrame` stops at its first frame.
///
/// DEBUG builds with `CMUX_MOBILE_LAUNCH_MARKS=1` also show the marks as one
/// JSON object in a nearly transparent label, `debug.launch-marks` (its
/// accessibility value), which `LaunchTTIUITests` and the all-UI-states
/// capture suites (`UIStateCapture.swift`) read.
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

    #if DEBUG
    /// Takes `name` at the first frame after the next one where no layer in the
    /// app's windows holds an animation (a push, a sheet, a scroll settling),
    /// or once `bound` seconds pass (a spinner animates for ever), once per
    /// process: the capture suites shoot a state once it stops moving, not
    /// after a fixed pause. The walk runs once per frame, only until then.
    public func markWhenStill(_ name: String, bound: TimeInterval = 3) {
        guard !has(name), pending.insert(name).inserted else { return }
        let deadline = CACurrentMediaTime() + bound
        var frames = 0
        FrameLoop.run { [self] in
            frames += 1
            // The frame right after the change can come before its animations are added.
            guard frames > 1 else { return false }
            guard CACurrentMediaTime() >= deadline || !Self.anyLayerAnimating() else { return false }
            pending.remove(name)
            mark(name)
            return true
        }
    }

    private static func anyLayerAnimating() -> Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            (scene as? UIWindowScene)?.windows.contains { !$0.isHidden && animating($0.layer) } ?? false
        }
    }

    private static func animating(_ layer: CALayer) -> Bool {
        if layer.animationKeys()?.isEmpty == false { return true }
        return layer.sublayers?.contains(where: animating) ?? false
    }
    #endif

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
/// A display link that calls `step` every frame until it returns true.
@MainActor
private final class FrameLoop: NSObject {
    private var link: CADisplayLink?
    private var step: (() -> Bool)?
    private static var live: Set<FrameLoop> = []

    static func run(_ step: @escaping () -> Bool) {
        let loop = FrameLoop()
        loop.step = step
        let link = CADisplayLink(target: loop, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        loop.link = link
        live.insert(loop)
    }

    @objc private func tick() {
        guard let step, step() else { return }
        link?.invalidate()
        link = nil
        self.step = nil
        Self.live.remove(self)
    }
}

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
