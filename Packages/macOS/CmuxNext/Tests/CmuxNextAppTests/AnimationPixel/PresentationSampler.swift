import AppKit
import QuartzCore

/// The layer channel: at every display refresh of the window's screen (its own display link, not
/// the app's clock), the rect of every named view in window points, and whether its presentation
/// layer shows a different frame than its model layer (an implicit animation the layout did not
/// ask for). The pixel channel (``WindowFrameStream``) says what was drawn; this one says which
/// view drew off the device-pixel grid.
@MainActor
final class PresentationSampler: NSObject {
    struct Sample {
        /// The display link's timestamp (CACurrentMediaTime's clock).
        let time: Double
        let rects: [String: CGRect]
        /// Views whose presentation frame differs from their model frame.
        let implicit: [String]
    }

    private(set) var samples: [Sample] = []
    /// Each view's model frame at the previous refresh: a presentation frame may show it (the
    /// commit of a change made in this refresh comes after this tick).
    private var previousModel: [String: CGRect] = [:]
    private var link: CADisplayLink?
    private let views: () -> [String: NSView]

    /// `views` names the views to sample; it is read again at every refresh, so views that come
    /// and go (a new pane) are sampled while they exist.
    init(window: NSWindow, views: @escaping () -> [String: NSView]) {
        self.views = views
        super.init()
        // concurrency-allow: a test's own display link, invalidated by `stop`
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        var rects: [String: CGRect] = [:], implicit: [String] = [], models: [String: CGRect] = [:]
        for (name, view) in views() where view.window != nil && !view.isHiddenOrHasHiddenAncestor {
            rects[name] = view.convert(view.bounds, to: nil)
            guard let layer = view.layer else { continue }
            models[name] = layer.frame
            // A presentation frame that is neither this refresh's model nor the last one's is an animation in flight.
            if let shown = layer.presentation()?.frame, shown != layer.frame, shown != previousModel[name] {
                implicit.append(name)
            }
        }
        previousModel = models
        samples.append(Sample(time: link.timestamp, rects: rects, implicit: implicit))
    }

    /// Failures of the samples from `from` on: an edge of a view off the device-pixel grid
    /// (`scale` pixels per point), and a presentation frame that is not the model frame.
    func gridFailures(from start: Double, scale: CGFloat) -> [String] {
        var failures: [String] = []
        for sample in samples where sample.time >= start {
            for (name, rect) in sample.rects.sorted(by: { $0.key < $1.key }) {
                let edges = [("minX", rect.minX), ("maxX", rect.maxX), ("minY", rect.minY), ("maxY", rect.maxY)]
                for (edge, value) in edges where abs(value * scale - (value * scale).rounded()) > 0.01 {
                    failures.append("t=\(Self.ms(sample.time - start)) ms: \(name) \(edge) at \(String(format: "%.3f", value * scale)) device px, off the pixel grid")
                }
            }
            for name in sample.implicit {
                failures.append("t=\(Self.ms(sample.time - start)) ms: \(name) shows a presentation frame that is not its model frame (an implicit animation)")
            }
        }
        return failures
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    /// Display refreshes the main thread missed from `start` to `end` (a tick interval over 1.5
    /// periods), with each gap in milliseconds.
    func missedRefreshes(from start: Double, to end: Double, period: Double) -> [Double] {
        let times = samples.map(\.time).filter { $0 >= start && $0 <= end }
        return zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 1.5 * period }.map { $0 * 1000 }
    }
}
