import CoreGraphics
import Foundation

/// The picture size a viewer needs, and the size the host captures at: the
/// viewer reports the long edge the streamed display takes on its screen
/// (``ScreenStreamViewer/viewDemandMessage``) and the host captures at the
/// smallest rung that covers it once the change held long enough. The rules
/// (rungs, holds, the fit) are cmux-rd-screen's `demand` (ops
/// `screen_demand_report`, `screen_demand_fit`); this keeps its state.
struct ViewerDemand: Sendable {
    private let rules: ScreenRules
    private var state: ScreenJSON?

    init(rules: ScreenRules = ScreenRules()) {
        self.rules = rules
    }

    /// The long edge the host captures at; nil: the display's own size.
    var cap: Int? { state?["cap"]?.int }

    /// Takes one viewer report at `now` (seconds on a monotonic clock) and
    /// returns whether ``cap`` changed.
    mutating func report(longEdge: Int, displayLongEdge: Int, pinch: Bool, now: TimeInterval) -> Bool {
        struct Request: Encodable { var demand: ScreenJSON?, longEdge: Int, displayLongEdge: Int, pinch: Bool, now: Double }
        struct Answer: Decodable { var demand: ScreenJSON, changed: Bool }
        let request = Request(demand: state, longEdge: longEdge, displayLongEdge: displayLongEdge, pinch: pinch, now: now)
        guard let answer = rules.ask("screen_demand_report", request, as: Answer.self) else { return false }
        state = answer.demand
        return answer.changed
    }

    private struct Fit: Decodable { var size: ScreenSize, captureCap: Int? }

    private static func fit(_ size: CGSize, cap: Int?, demand: Int?, quality: ScreenQuality, scales: Bool, rules: ScreenRules) -> Fit? {
        struct Request: Encodable { var size: ScreenSize, cap: Int?, demand: Int?, quality: ScreenQuality, scales: Bool }
        return rules.ask("screen_demand_fit", Request(size: ScreenSize(size), cap: cap, demand: demand, quality: quality, scales: scales))
    }

    /// `size` scaled down to fit `cap` on its long edge (even sides, as the
    /// encoder wants); unchanged when it already fits, there is no cap or no rules.
    static func fit(_ size: CGSize, cap: Int?, rules: ScreenRules) -> CGSize {
        guard cap != nil, let answer = fit(size, cap: cap, demand: nil, quality: .auto, scales: false, rules: rules) else { return size }
        return answer.size.cgSize
    }

    /// The long edge the source captures at for ``cap``: only under an
    /// adaptive quality and for a source that scales.
    func captureCap(quality: ScreenQuality, scales: Bool) -> Int? {
        let demand = cap
        guard demand != nil else { return nil }
        return Self.fit(.zero, cap: nil, demand: demand, quality: quality, scales: scales, rules: rules)?.captureCap
    }
}
