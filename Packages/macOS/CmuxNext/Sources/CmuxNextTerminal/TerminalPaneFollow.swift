import AppKit
public import CoreGraphics
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One frame of a shown terminal against its pane (`debug.terminal_display`, the terminal resize bench's rule:
/// a drag or a key resize fails when a terminal does not change size with its pane). Sizes in points.
public nonisolated struct TerminalPaneFollowSizes: Sendable, Equatable {
    /// The size the surface takes in its host now (``TerminalHostView/surfaceSize(forHostSize:)``): its pane's size.
    public var area: CGSize
    /// The size the host gave the surface: the surface view's frame. Not `area` while the surface is held.
    public var asked: CGSize
    /// What shows: the last frame Ghostty showed on the surface layer (its present callback, ``TerminalPresents``), in
    /// points at the layer's scale; zero before the first frame.
    public var shown: CGSize

    public init(area: CGSize, asked: CGSize, shown: CGSize) {
        self.area = area
        self.asked = asked
        self.shown = shown
    }
}

/// One terminal's frames against its pane over a run of `debug.terminal_display`: frames sampled, frames in which the
/// host asked the surface for another size than its pane's (held), frames in which the layer showed another size than
/// its pane's (lagging), and the first few held and lagging ones. A size differs when either axis is more than ``tolerance`` off.
public nonisolated struct TerminalPaneFollowTally: Sendable, Equatable, Encodable {
    /// One frame that differed: its index in the run (from 0) and its sizes, encoded as [width, height] in points.
    public nonisolated struct Mismatch: Sendable, Equatable, Encodable {
        public var frame: Int
        public var sizes: TerminalPaneFollowSizes

        nonisolated enum CodingKeys: String, CodingKey { case frame, area, asked, shown }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            func pair(_ size: CGSize) -> [Double] { [size.width, size.height].map { (Double($0) * 10).rounded() / 10 } }
            try container.encode(frame, forKey: .frame)
            try container.encode(pair(sizes.area), forKey: .area)
            try container.encode(pair(sizes.asked), forKey: .asked)
            try container.encode(pair(sizes.shown), forKey: .shown)
        }
    }

    public static let tolerance: CGFloat = 0.5
    /// Mismatches kept of each kind.
    public static let kept = 3

    public private(set) var frames = 0
    public private(set) var held = 0
    public private(set) var lagging = 0
    public private(set) var firstHeld: [Mismatch] = []
    public private(set) var firstLagging: [Mismatch] = []

    nonisolated enum CodingKeys: String, CodingKey {
        case frames, held, lagging, firstHeld = "first_held", firstLagging = "first_lagging"
    }

    public init() {}

    /// Counts frame `frame` of the run.
    public mutating func record(_ sizes: TerminalPaneFollowSizes, frame: Int) {
        frames += 1
        if Self.differ(sizes.asked, sizes.area) {
            held += 1
            if firstHeld.count < Self.kept { firstHeld.append(Mismatch(frame: frame, sizes: sizes)) }
        }
        if Self.differ(sizes.shown, sizes.area) {
            lagging += 1
            if firstLagging.count < Self.kept { firstLagging.append(Mismatch(frame: frame, sizes: sizes)) }
        }
    }

    static func differ(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) > tolerance || abs(a.height - b.height) > tolerance
    }
}

extension TerminalSession {
    /// This terminal's sizes against its pane now (``TerminalPaneFollowSizes``); nil when its surface is not shown in
    /// its host (no window, hidden or parked). Cheap: no Ghostty call.
    var paneFollowSizes: TerminalPaneFollowSizes? {
        let surface = surfaceView
        guard surface.isShown, surface.superview === view else { return nil }
        let asked = surface.frame.size
        let scale = max(surface.layer?.contentsScale ?? 1, 1)
        let shown = surface.bridge.takeUnretainedValue().presents.last
            .map { CGSize(width: CGFloat($0.widthPixels) / scale, height: CGFloat($0.heightPixels) / scale) } ?? .zero
        return TerminalPaneFollowSizes(area: view.surfaceSize(forHostSize: view.bounds.size), asked: asked, shown: shown)
    }
}

/// ``TerminalDisplayProbe``'s pane check: whether each shown terminal changes size with its pane in every frame of a
/// drag or a key resize (scripts/cmux-next/bench-terminal-resize.py).
///
/// From ``start(_:)`` to ``stop()``, each window that shows a followed terminal has a client on its own frame clock
/// (``FrameScheduler/forWindow(_:)``, the clock its layout springs tick on), which marks that
/// window's frames. An observer of the main run loop, last after Core Animation's commit (`beforeWaiting`, order
/// `CFIndex.max`), samples the terminals of each window whose frame ticked in that turn: a sample is the geometry that
/// turn's commit carried for that window's frame. It samples only the terminals shown at ``start(_:)`` (a drag or a key
/// resize shows no new terminal): O(those terminals) per frame, and nothing at all while it does not run. At most
/// ``maximumRun``: a client that never sends `stop` must not keep a display link running.
@MainActor
final class TerminalPaneFollowProbe {
    static let maximumRun: Duration = .seconds(600)

    private struct Followed {
        let key: String
        weak var session: TerminalSession?
        var tally = TerminalPaneFollowTally()
    }

    /// One followed window: its frame client, whether a frame ticked since the last sample, its frames sampled and its
    /// terminals (indices into ``followed``).
    private struct WindowClock {
        weak var window: NSWindow?
        let client: FrameClient
        var pending = false
        var frames = 0
        var members: [Int] = []
    }

    private var followed: [Followed] = []
    private var clocks: [ObjectIdentifier: WindowClock] = [:]
    /// Frames sampled since ``start(_:)``, summed over the followed windows.
    private(set) var frames = 0
    private var observer: CFRunLoopObserver?
    private let expiry = DemandTimer(owner: "debug.terminal_display.follow.expiry")

    /// Clears the record and starts sampling the terminals of `terminals` shown now, each on its window's frames.
    func start(_ terminals: [(key: String, session: TerminalSession)]) {
        stop()
        (frames, clocks) = (0, [:])
        followed = terminals.filter { $0.session.paneFollowSizes != nil }.map { Followed(key: $0.key, session: $0.session) }
        for (index, entry) in followed.enumerated() {
            guard let window = entry.session?.view.window else { continue }
            let id = ObjectIdentifier(window)
            if clocks[id] == nil {
                let client = FrameClient(owner: "debug.terminal_display.follow", isAnimation: false,
                                         on: FrameScheduler.forWindow(window)) { [weak self] _ in
                    self?.clocks[id]?.pending = true
                    return true
                }
                clocks[id] = WindowClock(window: window, client: client)
            }
            clocks[id]?.members.append(index)
        }
        guard !clocks.isEmpty else { return }
        for clock in clocks.values { clock.client.activate() }
        // Last after the commit (`CFIndex.max`); it only reads geometry: its context says so to the commit-boundary audit.
        let observer = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: CFIndex.max) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleFramedWindows() } // main-proof: an observer of the main run loop
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
    }

    /// Stops sampling; the record stays for ``tallies``.
    func stop() {
        expiry.cancel()
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        for id in clocks.keys {
            guard let clock = clocks[id], clock.client.isActive else { continue }
            clock.client.deactivate()
        }
    }

    /// Per terminal, by tab key.
    var tallies: [String: TerminalPaneFollowTally] {
        Dictionary(followed.map { ($0.key, $0.tally) }, uniquingKeysWith: { first, _ in first })
    }

    private func sampleFramedWindows() {
        for id in clocks.keys {
            guard let clock = clocks[id], clock.pending else { continue }
            clocks[id]?.pending = false
            for index in clock.members {
                guard let sizes = followed[index].session?.paneFollowSizes else { continue }
                followed[index].tally.record(sizes, frame: clock.frames)
            }
            clocks[id]?.frames += 1
            frames += 1
        }
    }
}
