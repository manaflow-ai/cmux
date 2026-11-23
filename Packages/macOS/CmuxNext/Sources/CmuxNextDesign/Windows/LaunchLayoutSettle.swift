public import AppKit
import CmuxNextWakeups

/// When a launch settles, for a launch harness: the last frame in which anything on screen moved, resized, appeared or
/// went away after the first window's first frame, and the largest move, in points, with the view that made it. Leo,
/// 2026-11-18: "well did you guys have more solution ideas tho for getting faster draws and settles?"
///
/// The app makes one only while a harness reads the launch marks (`LaunchMarkSink.isActive`,
/// `CMUX_NEXT_LAUNCH_MARKS_PATH`), so a person's launch pays nothing. Once a display frame of the app's clock it reads
/// the front window's view geometry (``WindowViewGeometry``, what the Debug `--record-launch` recording reads) and
/// compares it with the frame before. It stops after ``LaunchLayoutSettleTally/quietMs`` with no change, or
/// ``LaunchLayoutSettleTally/capMs`` after the first frame, and then writes its marks once:
///
///   `layout.first_frame`        ms since the process started: the first frame it read
///   `layout.settle`             ms since the process started: the last frame that changed (the first frame when none did)
///   `layout.max_move`           the largest move, in points (the value field carries points, not ms)
///   `layout.max_move.<View>`    the same, named by the view's type
///   `layout.last.<View>`        ms since the process started: the last change, named by a view it changed
///   `layout.changed_frames`     how many frames after the first changed (a count)
///   `layout.capped`             present when it stopped at the cap with changes still coming
///   `layout.cost_ms`            main-thread ms the watch itself spent reading geometry, so a reader can subtract it
///
/// A window that replaces the one being read (the launch window handed over to a restored one) is a change named
/// `window`, and the reading goes on in the new window.
@MainActor
public final class LaunchLayoutSettle {
    private var client: FrameClient?
    private var window: NSWindow?
    private var geometry: WindowViewGeometry?
    private var tally = LaunchLayoutSettleTally()
    private var costMs = 0.0
    private let frontWindow: @MainActor () -> NSWindow?
    private let now: () -> Double
    private let write: (String, Double) -> Void

    /// - Parameters:
    ///   - frontWindow: the window a person sees, or nil before the first one shows.
    ///   - now: ms since the process started (the launch marks' clock).
    ///   - write: writes one mark line (`LaunchMarkSink.write(name:ms:)`).
    public init(frontWindow: @escaping @MainActor () -> NSWindow?, now: @escaping () -> Double, write: @escaping (String, Double) -> Void) {
        self.frontWindow = frontWindow
        self.now = now
        self.write = write
    }

    /// Starts the launch's watch when `measured` (a harness reads the marks), before the first window is made. The front
    /// window is the key window when `isShell` takes it, else the frontmost visible window it takes.
    public static func start(when measured: Bool, isShell: @escaping @MainActor (NSWindow) -> Bool, now: @escaping () -> Double,
                             write: @escaping (String, Double) -> Void) {
        guard measured else { return }
        LaunchLayoutSettle(frontWindow: {
            if let key = NSApp.keyWindow, isShell(key), key.isVisible { return key }
            return NSApp.orderedWindows.first { isShell($0) && $0.isVisible }
        }, now: now, write: write).start()
    }

    /// Before the first window is made. The watch keeps itself until it ends: its frame client holds it, and the app's
    /// frame scheduler holds an active client (FrameClient), which it lets go when ``frame()`` returns false.
    public func start() {
        guard client == nil else { return }
        let client = FrameClient(owner: "launch.layout_settle", isAnimation: false, on: .app) { _ in
            self.frame()
        }
        self.client = client
        client.activate()
    }

    /// One display frame; false once the watch is over.
    private func frame() -> Bool {
        let now = now()
        // A launch that never shows a window stops looking after 30 s, and writes nothing.
        guard let front = frontWindow() else {
            if now < 30_000 { return true }
            client = nil // no window in 30 s: let go of the cycle through the client's closure
            return false
        }
        let started = CACurrentMediaTime()
        let read = WindowViewGeometry(window: front)
        defer { costMs += (CACurrentMediaTime() - started) * 1_000 }
        if let previous = geometry {
            if front !== window {
                tally.note(at: now, change: "window", move: nil)
            } else {
                let change = read.changes(since: previous, limit: 1)
                if change.total > 0 {
                    // Named by the view that moved farthest, else by the first change (a view that appeared or went away).
                    let move = read.largestMove(since: previous).map { (name: Self.markName($0.name), points: $0.points) }
                    let named = move?.name ?? change.lines.first.map(Self.markName) ?? "view"
                    tally.note(at: now, change: named, move: move)
                }
            }
        } else {
            tally.first(at: now)
        }
        window = front
        geometry = read
        guard tally.isOver(at: now) else { return true }
        for (name, value) in tally.marks() { write(name, value) }
        write("layout.cost_ms", costMs)
        geometry = nil
        window = nil
        client = nil // the cycle through the client's closure ends with the watch
        return false
    }

    /// A view's type as one word for a mark's name: up to its first space or generic argument
    /// (`NSHostingView<ModifiedContent<A, B>>` is `NSHostingView`), so a mark line stays `<name> <value>`.
    static func markName(_ name: String) -> String {
        let word = name.prefix { $0 != " " && $0 != "<" }
        return word.isEmpty ? "view" : String(word)
    }
}

/// What ``LaunchLayoutSettle`` adds up, frame by frame, and when it stops. Times are ms since the process started.
struct LaunchLayoutSettleTally {
    /// No change for this long after the last one: settled.
    static let quietMs = 1_500.0
    /// Read at most this long after the first frame (the launch harness quits the app 6 s after its window shows).
    static let capMs = 5_000.0

    private(set) var firstMs: Double?
    private(set) var lastChangeMs: Double?
    private(set) var lastChanged = ""
    private(set) var changedFrames = 0
    private(set) var largest: (name: String, points: Double)?

    mutating func first(at ms: Double) {
        if firstMs == nil { firstMs = ms }
    }

    /// A frame after the first in which `change` (a view's type, or `window`) changed, with the frame's largest move.
    mutating func note(at ms: Double, change: String, move: (name: String, points: Double)?) {
        guard firstMs != nil else { return first(at: ms) }
        changedFrames += 1
        lastChangeMs = ms
        lastChanged = change
        if let move, move.points > (largest?.points ?? 0) { largest = move }
    }

    func isOver(at ms: Double) -> Bool {
        guard let firstMs else { return false }
        return ms - (lastChangeMs ?? firstMs) >= Self.quietMs || ms - firstMs >= Self.capMs
    }

    /// The marks, once over (see ``LaunchLayoutSettle``).
    func marks() -> [(String, Double)] {
        guard let firstMs else { return [] }
        let settle = lastChangeMs ?? firstMs
        var marks: [(String, Double)] = [("layout.first_frame", firstMs), ("layout.settle", settle),
                                         ("layout.max_move", largest?.points ?? 0), ("layout.changed_frames", Double(changedFrames))]
        if let largest { marks.append(("layout.max_move.\(largest.name)", largest.points)) }
        if lastChangeMs != nil { marks.append(("layout.last.\(lastChanged)", settle)) }
        // Still changing in its last quiet span: the cap ended it, not a settle.
        if let lastChangeMs, lastChangeMs - firstMs > Self.capMs - Self.quietMs { marks.append(("layout.capped", settle)) }
        return marks
    }
}
