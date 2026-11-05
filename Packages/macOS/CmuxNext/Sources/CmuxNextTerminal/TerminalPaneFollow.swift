public import CoreGraphics
import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// One display frame of a shown terminal against its pane (`debug.terminal_display`, the terminal resize bench's rule:
/// a drag or a key resize fails when a terminal does not change size with its pane). Sizes in points.
public nonisolated struct TerminalPaneFollowSizes: Sendable, Equatable {
    /// The size the surface takes in its host now (``TerminalHostView/surfaceSize(forHostSize:)``): its pane's size.
    public var area: CGSize
    /// The size the host asked of the surface: the frame it wants while its window's commit owns the frame
    /// (`motion.frameOwner.terminals`), else the surface view's frame. Not `area` while the surface is held.
    public var asked: CGSize
    /// What shows: the surface layer's bounds.
    public var shown: CGSize

    public init(area: CGSize, asked: CGSize, shown: CGSize) {
        self.area = area
        self.asked = asked
        self.shown = shown
    }
}

/// One terminal's frames against its pane over a run of `debug.terminal_display`: frames sampled, frames in which the
/// host asked the surface for another size than its pane's (held), frames in which the layer showed another size than
/// its pane's (lagging), and the first few of each. A size differs when either axis is more than ``tolerance`` off.
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
        let ownership = surface.frameOwnership
        let asked = ownership.embedderPresents ? (ownership.wanted?.size ?? surface.frame.size) : surface.frame.size
        return TerminalPaneFollowSizes(area: view.surfaceSize(forHostSize: view.bounds.size), asked: asked,
                                       shown: surface.layer?.bounds.size ?? surface.bounds.size)
    }
}

/// ``TerminalDisplayProbe``'s pane check: whether each shown terminal changes size with its pane in every frame of a
/// drag or a key resize (scripts/cmux-next/bench-terminal-resize.py).
///
/// From ``start(_:)`` to ``stop()``, a frame clock marks each display frame and an observer after Core Animation's
/// commit samples once per marked frame, so a sample is what that frame showed. It samples only the terminals shown at
/// ``start(_:)`` (a drag or a key resize shows no new terminal): O(those terminals) per frame, and nothing at all while
/// it does not run. At most ``maximumRun``: a client that never sends `stop` must not keep the display link running.
@MainActor
final class TerminalPaneFollowProbe {
    static let maximumRun: Duration = .seconds(600)

    private struct Followed {
        let key: String
        weak var session: TerminalSession?
        var tally = TerminalPaneFollowTally()
    }

    private var followed: [Followed] = []
    /// Display frames sampled since ``start(_:)``.
    private(set) var frames = 0
    private var framePending = false
    private var observer: CFRunLoopObserver?
    private lazy var clock = FrameClient(owner: "debug.terminal_display.follow", isAnimation: false, on: .app) { [weak self] _ in
        self?.framePending = true
        return true
    }
    private let expiry = DemandTimer(owner: "debug.terminal_display.follow.expiry")

    /// Clears the record and starts sampling the terminals of `terminals` shown now.
    func start(_ terminals: [(key: String, session: TerminalSession)]) {
        stop()
        frames = 0
        framePending = false
        followed = terminals.filter { $0.session.paneFollowSizes != nil }.map { Followed(key: $0.key, session: $0.session) }
        guard !followed.isEmpty else { return }
        clock.activate()
        // Last after the commit (`CFIndex.max`); it only reads geometry: its context says so to the commit-boundary audit.
        let observer = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: CFIndex.max) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleIfFramed() } // main-proof: an observer of the main run loop
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
    }

    /// Stops sampling; the record stays for ``tallies``.
    func stop() {
        clock.deactivate()
        expiry.cancel()
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
    }

    /// Per terminal, by tab key.
    var tallies: [String: TerminalPaneFollowTally] {
        Dictionary(followed.map { ($0.key, $0.tally) }, uniquingKeysWith: { first, _ in first })
    }

    private func sampleIfFramed() {
        guard framePending else { return }
        framePending = false
        for index in followed.indices {
            guard let sizes = followed[index].session?.paneFollowSizes else { continue }
            followed[index].tally.record(sizes, frame: frames)
        }
        frames += 1
    }
}
