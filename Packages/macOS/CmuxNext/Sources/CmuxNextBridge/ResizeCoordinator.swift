public import AppKit
import CmuxNextDesign
public import CmuxNextDaemon
import CmuxNextWakeups

/// A view whose settled grid goes to the PTY owner (`DaemonTerminalIO`).
@MainActor public protocol ResizeTarget: AnyObject {
    func applySettled(_ size: CellSize)
    /// The daemon has not echoed this view's last grid yet.
    var awaitsEcho: Bool { get }
}

/// Sends terminal grid changes to the daemon the next frame, with at most one
/// grid in flight per terminal (perf I7; Lawrence 2026-10-17: everything in a
/// drag is real time). A divider drag, a live window resize, a sidebar slide
/// or a layout spring changes a pane's size every frame, and the text reflows
/// with it. Every daemon resize reflows the PTY and echoes a rebuilt screen,
/// so while a terminal's last grid has not echoed its next one waits, and the
/// newest size (never the ones in between) goes the frame the echo comes: the
/// daemon never queues stale sizes. An echo that does not come within
/// `echoWaitFrames` (a refused or lost resize) stops holding the newest size.
public final class ResizeCoordinator {
    /// Frames a size waits for the echo of the grid before it.
    public static let echoWaitFrames = 30
    /// Grids sent to the daemon (`debug.window_transition`), a diagnostic count.
    public static var sent: UInt64 = 0

    /// Told each grid sent, with its terminal's identity (`debug.terminal_final_grid`, DEBUG builds).
    public var onSend: ((ObjectIdentifier, CellSize) -> Void)?

    private var settle = ResizeSettle<ObjectIdentifier, CellSize>(stableFrames: 1)
    private var targets: [ObjectIdentifier: any ResizeTarget] = [:]
    private var windows: [ObjectIdentifier: WeakWindow] = [:]
    private var waited: [ObjectIdentifier: Int] = [:]
    /// Whether sizes in a window wait: its full screen enter or exit
    /// (`Motion.isFullScreenTransitioning(_:)`). AppKit animates a snapshot to
    /// the final size, so no in-between size shows; each one the daemon
    /// applied was a PTY reflow and a rebuilt screen for nothing, on the
    /// main thread the animation needs (fullscreen-lag). The newest size
    /// goes the frame after it ends. Terminals in other windows do not wait
    /// (PL-burst M6), and a drag stays real time (it does not hold).
    private let holds: (NSWindow?) -> Bool

    /// One coordinator for the app, made by its composition root (`AppServices`); pane sizes span
    /// windows, so the frames run on the app scheduler.
    /// - Parameter holds: Whether sizes in a window wait this frame; nil (the app) holds a window's
    ///   sizes during its full screen transition, tests pass their own.
    public init(holds: ((NSWindow?) -> Bool)? = nil) {
        self.holds = holds ?? { Motion.isFullScreenTransitioning($0) }
    }

    private lazy var frames = FrameClient(owner: "ResizeCoordinator.settle", isAnimation: false, on: .app) { [weak self] _ in
        self?.tick() ?? false
    }

    /// Sends `size` to `io` the next frame, unless its last grid has not echoed or its window holds.
    /// - Parameters:
    ///   - io: The terminal's PTY owner.
    ///   - size: The grid.
    ///   - window: The terminal's window, for its full screen hold; nil holds nothing.
    public func submit(_ io: any ResizeTarget, size: CellSize, window: NSWindow? = nil) {
        let key = ObjectIdentifier(io)
        targets[key] = io
        windows[key] = WeakWindow(window: window)
        settle.submit(key, size: size)
        frames.activate()
    }

    /// Sends the grid a terminal will have when its pane's layout spring lands, now, in the caller's
    /// turn (Lawrence 2026-10-23: Cmd-D and Cmd-W resize the program in the terminal at the start of
    /// the spring, not after it). The one-in-flight rule still applies: while the terminal's last grid
    /// has not echoed, this grid waits as the newest one and goes the frame the echo comes, and so does
    /// a grid whose window is in a full screen transition, at its end.
    ///
    /// - Parameters:
    ///   - io: The terminal's PTY owner.
    ///   - size: The final grid.
    ///   - window: The terminal's window, for its full screen hold; nil holds nothing.
    public func submitFinal(_ io: any ResizeTarget, size: CellSize, window: NSWindow? = nil) {
        guard holds(window) || io.awaitsEcho else {
            let key = ObjectIdentifier(io)
            settle.cancel(key)
            targets[key] = nil
            windows[key] = nil
            waited[key] = nil
            Self.sent &+= 1
            onSend?(key, size)
            io.applySettled(size)
            return
        }
        submit(io, size: size, window: window)
    }

    public func cancel(_ io: any ResizeTarget) {
        let key = ObjectIdentifier(io)
        settle.cancel(key)
        targets[key] = nil
        windows[key] = nil
        waited[key] = nil
    }

    /// Whether no grid waits to go to its PTY: none submitted and unsent (`debug.burst status`).
    public var isIdle: Bool { settle.isIdle }

    /// One frame; false once every size went.
    public func tick() -> Bool {
        for (key, size) in settle.tick() {
            // A held window's size keeps waiting; the frames keep running until its transition ends.
            if holds(windows[key]?.window) {
                settle.submit(key, size: size)
                continue
            }
            if targets[key]?.awaitsEcho == true, waited[key, default: 0] < Self.echoWaitFrames {
                waited[key, default: 0] += 1
                settle.submit(key, size: size)
                continue
            }
            waited[key] = nil
            windows[key] = nil
            guard let target = targets.removeValue(forKey: key) else { continue }
            Self.sent &+= 1
            onSend?(key, size)
            target.applySettled(size)
        }
        return !settle.isIdle
    }
}

/// A terminal's window, held weakly (`ResizeCoordinator`): a closed window holds nothing.
private struct WeakWindow {
    weak var window: NSWindow?
}
