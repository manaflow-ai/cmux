public import AppKit
public import CmuxNextDesign
import CmuxNextSignposts
import QuartzCore

/// Per new workspace, the time from its create to the frame that first draws its sidebar row.
///
/// Every build: the `create.workspace` interval (``SignpostName/createWorkspace``), one async pair per create
/// that has a row (`os_signpost`, the MetricKit mirror and the trace ring's AB/AE). It begins when the create
/// names its workspace (``began(_:)``, in the press's turn) with the triggering event's age in the top 24 bits of
/// `arg0`, and ends at the ``CommitBoundary`` after the turn whose sidebar pass drew the row (``drew(_:in:)``). A
/// create whose row goes before it was drawn (the create failed, a close took it: ``forget(_:)``) ends as missed
/// (`commit=missed`), so readers and MetricKit drop it. Every begin gets exactly one end. Chrome times a new tab
/// the same way: one async trace event from the input to the presented frame, closed by
/// `ContentToVisibleTimeReporter` (content/browser/renderer_host/visible_time_request_trigger.h).
///
/// Debug: `debug.new_workspace` records the press (``pressed()``) to the frame its row is first drawn, as
/// `SwitchFrameTimer` times a tab switch (`apply_ms`, `commit_ms`, `late_vsyncs`), and `walks`: the rows passes that
/// walked every workspace (`SidebarRowFeed.fill`) between the two. A new workspace's row is drawn from the press,
/// before the daemon creates it (the App's PendingWorkspaceRows), so it needs no walk: perf-gate.py's
/// new_workspaces scenario gates `walks` 0 for every create.
@MainActor
public final class SidebarNewRowTimer {
    public static let shared = SidebarNewRowTimer()

    /// Runs a block once after the commit that ends this main run-loop turn.
    typealias Boundary = @MainActor (_ body: @escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void

    /// Its socket method reads and starts or stops this (the App's `debug.new_workspace`).
    public let timer = SwitchFrameTimer(owner: "debug.new_workspace")
    /// The presses whose create has not named its workspace yet, oldest first (creates run in press order).
    private var presses: [CFTimeInterval] = []
    /// The rebuild count at each create's press, by workspace id.
    private var walksAtPress: [String: Int] = [:]

    private struct Open {
        var serial: UInt64
        var interval: SignpostInterval
        /// Its row was drawn: the boundary of that turn ends it.
        var ending = false
    }

    /// Creates whose row has not been drawn and committed yet, by workspace id, oldest first.
    private var open: [(id: String, create: Open)] = []
    private var lastSerial: UInt64 = 0
    /// The most creates open at once; a begin past it ends the oldest as missed (its row never drew in any window).
    static let openLimit = 64
    private let signposter: Signposter
    private let boundary: Boundary
    private let inputAge: @MainActor () -> Double

    convenience init() {
        self.init(signposter: .create, boundary: { CommitBoundary().after($0) }, inputAge: Self.currentInputAge)
    }

    /// - Parameters:
    ///   - signposter: The create category's signposter (tests pass one on their own trace runtime).
    ///   - boundary: Runs an end after this turn's commit (tests fire it themselves).
    ///   - inputAge: The triggering event's age in milliseconds now, or -1 without one.
    init(signposter: Signposter, boundary: @escaping Boundary, inputAge: @escaping @MainActor () -> Double) {
        self.signposter = signposter
        self.boundary = boundary
        self.inputAge = inputAge
        timer.onStart = { [weak self] in
            self?.presses = []
            self?.walksAtPress = [:]
        }
    }

    /// How many creates wait for their row's commit (tests).
    var openCount: Int { open.count }

    /// A person or script asked for a new workspace (the App's `newTab` action), now.
    public func pressed() {
        guard timer.isRecording else { return }
        presses.append(CACurrentMediaTime())
    }

    /// The create of the oldest press (else one with no press, from now) is workspace `id`, and its row is
    /// about to list: begins its `create.workspace` interval.
    public func began(_ id: String) {
        beginInterval(id)
        guard timer.isRecording else { return }
        walksAtPress[id] = Self.walks
        timer.began(id, at: presses.isEmpty ? CACurrentMediaTime() : presses.removeFirst())
    }

    /// The row of workspace `id` went before it was drawn (its create failed or a close took it): its interval
    /// ends as missed. One whose row was drawn ends at its boundary as before.
    public func forget(_ id: String) {
        if let index = open.firstIndex(where: { $0.id == id }), !open[index].create.ending {
            signposter.end(.createWorkspace, open.remove(at: index).create.interval, .missed)
        }
        guard timer.isRecording, walksAtPress.removeValue(forKey: id) != nil else { return }
        timer.forget(id)
    }

    /// The list of `window` drew `sections`: a waiting workspace listed there is shown.
    func drew(_ sections: [SidebarSection], in window: NSWindow?) {
        let recording = timer.isRecording && !walksAtPress.isEmpty
        guard recording || open.contains(where: { !$0.create.ending }) else { return }
        for section in sections {
            for workspace in section.workspaces {
                let id = workspace.id.rawValue
                rowDrawn(id)
                guard recording, let walks = walksAtPress[id], timer.isWaiting(id) else { continue }
                walksAtPress[id] = nil
                timer.shown(id, in: window, extra: ["walks": Double(Self.walks - walks)])
            }
        }
    }

    private func beginInterval(_ id: String) {
        if let index = open.firstIndex(where: { $0.id == id }) {
            signposter.end(.createWorkspace, open.remove(at: index).create.interval, .missed)
        }
        if open.count >= Self.openLimit {
            signposter.end(.createWorkspace, open.removeFirst().create.interval, .missed)
        }
        lastSerial &+= 1
        let interval = signposter.beginCreateWorkspace(inputAgeMilliseconds: inputAge())
        open.append((id: id, create: Open(serial: lastSerial, interval: interval)))
    }

    /// The row of `id` is drawn in this turn: its open interval ends at this turn's commit boundary, once.
    private func rowDrawn(_ id: String) {
        guard let index = open.firstIndex(where: { $0.id == id }), !open[index].create.ending else { return }
        open[index].create.ending = true
        let serial = open[index].create.serial
        boundary { [weak self] outcome in self?.boundaryFired(id, serial: serial, outcome) }
    }

    private func boundaryFired(_ id: String, serial: UInt64, _ outcome: CommitBoundary.Outcome) {
        guard let index = open.firstIndex(where: { $0.id == id && $0.create.serial == serial }) else { return }
        signposter.end(.createWorkspace, open.remove(at: index).create.interval, outcome)
    }

    /// The current event's age in milliseconds when it is a key or click from the last second, else -1.
    private static func currentInputAge() -> Double {
        guard let event = NSApp?.currentEvent, [.keyDown, .leftMouseDown, .leftMouseUp].contains(event.type) else { return -1 }
        let age = CACurrentMediaTime() - event.timestamp
        return age >= 0 && age < 1 ? age * 1_000 : -1
    }

    private static var walks: Int { SidebarPerfCounters.count(.rebuilds) }
}
