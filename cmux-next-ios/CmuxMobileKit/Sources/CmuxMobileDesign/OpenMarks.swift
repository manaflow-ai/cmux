#if os(iOS) && DEBUG
import Foundation
import Observation
import QuartzCore
import SwiftUI

/// Opening something inside a running app, measured from inside the app (DEBUG only, on with
/// `CMUX_MOBILE_LAUNCH_MARKS=1`, like `LaunchMarks` and `ResumeMarks`; `LaunchTTIOpenPathsUITests`).
/// `LaunchMarks` takes each mark once per process, so it times a launch's first open only; these
/// repeat, so one process can time a session switch, a deep link and a notification tap again
/// and again (the optimum ledger's `ios-session-switch`, `ios-deep-link`, `ios-notification-tap`).
///
/// Each open starts a cycle (``begin(_:)``) at its trigger (`CACurrentMediaTime`, monotonic):
/// - `workspace_row_tap`: a workspace row was tapped (`WorkspacesList.openWorkspace`)
/// - `deep_link`: the system handed the app a URL (`onOpenURL`, a universal link)
/// - `notification_tap`: the person opened one of the app's notifications
///
/// The marks are ms since that trigger, each taken once per cycle:
/// - `route_opened`: a waiting route (a deep link's, a notification's) was opened by the shell
/// - `chat_composer_ready`: a frame showing an agent chat's composer was presented
/// - `terminal_ready`: a terminal attached to its session presented a frame
///
/// The board is one JSON object in a nearly transparent label, `debug.open-marks`. Cost: off,
/// nothing; on, a dictionary write per mark and a one-shot display link per composer mark.
@MainActor
@Observable
public final class OpenMarks {
    public static let shared: OpenMarks? =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_LAUNCH_MARKS"] == "1" ? OpenMarks() : nil

    public private(set) var text = #"{"cycle":0}"#

    @ObservationIgnored private var cycle = 0
    @ObservationIgnored private var trigger: String?
    @ObservationIgnored private var origin: CFTimeInterval?
    @ObservationIgnored private var stamps: [String: Double] = [:]
    @ObservationIgnored private var pending: Set<String> = []

    private init() {}

    /// Starts a cycle at `trigger`, now.
    public func begin(_ trigger: String) {
        cycle += 1
        self.trigger = trigger
        origin = CACurrentMediaTime()
        stamps = [:]
        pending = []
        publish()
    }

    /// Takes `name` now, once per cycle (nothing before the first trigger).
    public func note(_ name: String) {
        guard let origin, stamps[name] == nil else { return }
        stamps[name] = (CACurrentMediaTime() - origin) * 1000
        publish()
    }

    /// Takes `name` when the next frame is presented, once per cycle.
    public func noteNextFrame(_ name: String) {
        guard origin != nil, stamps[name] == nil, pending.insert(name).inserted else { return }
        let started = cycle
        OpenFrame.after { [self] in
            guard cycle == started else { return }
            pending.remove(name)
            note(name)
        }
    }

    private func publish() {
        var parts = [#""cycle":\#(cycle)"#]
        if let trigger { parts.append(#""trigger":"\#(trigger)""#) }
        parts += stamps.sorted { $0.key < $1.key }.map { String(format: "\"%@\":%.1f", $0.key, $0.value) }
        text = "{" + parts.joined(separator: ",") + "}"
    }
}

/// A display link that fires once, at the next frame, then stops.
@MainActor
private final class OpenFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?
    private static var live: Set<OpenFrame> = []

    static func after(_ action: @escaping @MainActor () -> Void) {
        let frame = OpenFrame()
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

/// The board as a nearly transparent label (`debug.open-marks`), over the app's root.
public struct OpenMarksProbe: View {
    public init() {}

    public var body: some View {
        if let marks = OpenMarks.shared {
            Text(marks.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.open-marks")
                .accessibilityLabel(marks.text)
        }
    }
}
#endif
