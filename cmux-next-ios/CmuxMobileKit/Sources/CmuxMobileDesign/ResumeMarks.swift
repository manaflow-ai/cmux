#if os(iOS) && DEBUG
import Foundation
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Resume after an app switch, measured from inside the app (DEBUG only, on with
/// `CMUX_MOBILE_LAUNCH_MARKS=1`, like `LaunchMarks`; `ResumeFromSwitchUITests`).
///
/// Each return to the foreground starts a cycle at `willEnterForeground`
/// (`CACurrentMediaTime`, monotonic); the marks are ms since then, each taken once
/// per cycle:
/// - `active`: `didBecomeActive`
/// - `frame`: the first frame presented after the return (any content)
/// - `terminal_frame`: a terminal presented a frame while attached to its session
/// - `terminal_detached`: a terminal presented a frame while not attached (a
///   reconnecting or held state after the return)
/// - `terminal_key_sent`: a typed key the attached terminal's session took
///
/// `away_ms` is the time in the background before the cycle. The board is one JSON
/// object in a nearly transparent label, `debug.resume-marks`. Cost: off, nothing;
/// on, three notification observers and a one-shot display link per return.
@MainActor
@Observable
public final class ResumeMarks {
    public static let shared: ResumeMarks? =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_LAUNCH_MARKS"] == "1" ? ResumeMarks() : nil

    /// Starts observing (call once, early, on main).
    public static func startIfRequested() { _ = shared }

    public private(set) var text = #"{"cycle":0}"#

    @ObservationIgnored private var cycle = 0
    @ObservationIgnored private var background: CFTimeInterval?
    @ObservationIgnored private var foreground: CFTimeInterval?
    @ObservationIgnored private var awayMs: Double?
    @ObservationIgnored private var stamps: [String: Double] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ResumeMarks.shared?.background = CACurrentMediaTime() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ResumeMarks.shared?.enteredForeground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ResumeMarks.shared?.note("active") }
        })
    }

    private func enteredForeground() {
        let now = CACurrentMediaTime()
        cycle += 1
        foreground = now
        awayMs = background.map { (now - $0) * 1000 }
        stamps = [:]
        publish()
        ResumeFrame.after { ResumeMarks.shared?.note("frame") }
    }

    /// Takes `name` now, once per cycle (nothing before the first return).
    public func note(_ name: String) {
        guard let foreground, stamps[name] == nil else { return }
        stamps[name] = (CACurrentMediaTime() - foreground) * 1000
        publish()
    }

    private func publish() {
        var parts = [#""cycle":\#(cycle)"#]
        if let awayMs { parts.append(String(format: "\"away_ms\":%.1f", awayMs)) }
        parts += stamps.sorted { $0.key < $1.key }.map { String(format: "\"%@\":%.1f", $0.key, $0.value) }
        text = "{" + parts.joined(separator: ",") + "}"
    }
}

/// A display link that fires once, at the next frame, then stops.
@MainActor
private final class ResumeFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?
    private static var live: Set<ResumeFrame> = []

    static func after(_ action: @escaping @MainActor () -> Void) {
        let frame = ResumeFrame()
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

/// The board as a nearly transparent label (`debug.resume-marks`), over the app's root.
public struct ResumeMarksProbe: View {
    public init() {}

    public var body: some View {
        if let marks = ResumeMarks.shared {
            Text(marks.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.resume-marks")
                .accessibilityLabel(marks.text)
        }
    }
}
#endif
