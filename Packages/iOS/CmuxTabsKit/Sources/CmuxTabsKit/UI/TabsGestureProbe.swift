#if os(iOS) && DEBUG
import Observation
import QuartzCore
import SwiftUI

/// DEBUG measurement of the bar swipe up (environment
/// `CMUX_TABS_GESTURE_PROBE=1`; off, it costs one Bool read per call).
/// Each display frame from the drag's first move to 0.8 s after the lift
/// records the frame's timestamp, where the page point that was under the
/// thumb at the start is drawn (the page rect TabsView rendered last) and
/// the thumb's location that render was built from. `TabsGestureProbeTests` (UITests) drives a
/// scripted drag, reads `published` from the hidden `tabs.gestureProbe`
/// element and reports tracking error and frame times.
@MainActor
@Observable
final class TabsGestureProbe {
    static let shared = TabsGestureProbe()
    nonisolated static let enabled = ProcessInfo.processInfo.environment["CMUX_TABS_GESTURE_PROBE"] == "1"

    /// "t,fingerX,fingerY,heldX,heldY,lifted" per frame, `;`-separated; set when a run ends.
    private(set) var published = ""
    /// Runs measured so far (the test waits for it to change).
    private(set) var runs = 0

    @ObservationIgnored private var startFinger: CGPoint?
    @ObservationIgnored private var startRect: CGRect = .zero
    @ObservationIgnored private var finger: CGPoint = .zero
    @ObservationIgnored private var rect: CGRect = .zero
    /// The thumb as it was when `rect` was rendered (the pair the frame shows).
    @ObservationIgnored private var drawnFinger: CGPoint = .zero
    @ObservationIgnored private var liftedAt: CFTimeInterval?
    @ObservationIgnored private var lastMove: CFTimeInterval = 0
    @ObservationIgnored private var rows: [String] = []
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private lazy var target = ProbeLinkTarget { [weak self] l in self?.tick(l) }

    /// The bar swipe's thumb (global points); the first call starts a run.
    static func finger(_ location: CGPoint, page: CGRect) {
        guard enabled else { return }
        shared.move(location, page: page)
    }

    static func lifted() {
        guard enabled else { return }
        shared.liftedAt = shared.liftedAt ?? CACurrentMediaTime()
    }

    /// The page rect TabsView is drawing (called from its body).
    static func drew(_ rect: CGRect) {
        guard enabled else { return }
        shared.rect = rect
        shared.drawnFinger = shared.finger
    }

    private func move(_ location: CGPoint, page: CGRect) {
        if startFinger == nil {
            startFinger = location
            startRect = page
            rect = page
            drawnFinger = location
            rows = []
            liftedAt = nil
            let l = CADisplayLink(target: target, selector: #selector(ProbeLinkTarget.fire(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
        finger = location
        lastMove = CACurrentMediaTime()
    }

    private func tick(_ l: CADisplayLink) {
        guard let s = startFinger else { return }
        // A drag whose bar went away mid-way (the grid settled under the
        // thumb) never ends: count it lifted a second after its last move.
        if liftedAt == nil, l.timestamp - lastMove > 1.0 { liftedAt = lastMove }
        let ax = startRect.width > 0 ? (s.x - startRect.minX) / startRect.width : 0
        let ay = startRect.height > 0 ? (s.y - startRect.minY) / startRect.height : 0
        let held = CGPoint(x: rect.minX + ax * rect.width, y: rect.minY + ay * rect.height)
        let f = { (v: CGFloat) in String(format: "%.2f", Double(v)) }
        rows.append("\(String(format: "%.5f", l.timestamp)),\(f(drawnFinger.x)),\(f(drawnFinger.y)),\(f(held.x)),\(f(held.y)),\(liftedAt == nil ? 0 : 1)")
        if let up = liftedAt, l.timestamp - up > 0.8 {
            l.invalidate()
            link = nil
            startFinger = nil
            published = rows.joined(separator: ";")
            runs += 1
        }
    }
}

@MainActor
private final class ProbeLinkTarget: NSObject {
    let handler: @MainActor (CADisplayLink) -> Void
    init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler(link) }
}

/// The hidden element the UI test reads (only with the probe on).
struct TabsGestureProbeElement: View {
    var body: some View {
        if TabsGestureProbe.enabled {
            let probe = TabsGestureProbe.shared
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("tabs.gestureProbe")
                .accessibilityLabel("runs \(probe.runs)")
                .accessibilityValue(probe.published)
        }
    }
}
#endif
