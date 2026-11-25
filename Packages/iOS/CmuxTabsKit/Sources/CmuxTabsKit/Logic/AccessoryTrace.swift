import Foundation

/// What the screen drew of the page's accessory row (the composer and key
/// row) while one zoom ran: the opacity and scale its body applied, once per
/// evaluation. A DEBUG check (`CMUX_TABS_FRAME_LOG=1`, TabZoomFrameTimeUITests)
/// that the row rides the zoom instead of leaving the screen when it starts.
struct AccessoryTrace: Equatable, Sendable {
    struct Summary: Equatable, Sendable, Codable {
        var samples: Int
        var firstOpacity: Double
        var lastOpacity: Double
        /// Samples drawn part-faded (opacity between 0.1 and 0.9).
        var midFades: Int
        var firstScale: Double
        var lastScale: Double
        /// Drawn from the zoom's first frame, faded on the way and scaled
        /// with the page (see `rides`).
        var ridesZoom: Bool
        /// The largest move of the row's bottom edge between two frames
        /// while it is visible (opacity over 0.05), in points: the zoom's own
        /// glide stays well under `jumpLimit`; a relayout (the keyboard
        /// leaving mid-zoom) jumps by the keyboard's height.
        var maxStep: Double = 0
    }

    private(set) var opacities: [Double] = []
    private(set) var scales: [Double] = []
    private(set) var bottoms: [Double?] = []

    /// A frame-to-frame move of the visible row's bottom edge above this is a jump.
    static let jumpLimit = 120.0

    mutating func reset() {
        opacities = []
        scales = []
        bottoms = []
    }

    /// `bottom`: the row's bottom edge on screen, when known.
    mutating func note(opacity: Double, scale: Double, bottom: Double? = nil) {
        opacities.append(opacity)
        scales.append(scale)
        bottoms.append(bottom)
    }

    private var maxStep: Double {
        var worst = 0.0
        for i in bottoms.indices.dropFirst() {
            guard let a = bottoms[i - 1], let b = bottoms[i], max(opacities[i - 1], opacities[i]) > 0.05 else { continue }
            worst = max(worst, abs(b - a))
        }
        return worst
    }

    func summary(toOverview: Bool) -> Summary {
        var s = Summary(samples: opacities.count, firstOpacity: opacities.first ?? 0, lastOpacity: opacities.last ?? 0,
                        midFades: opacities.filter { $0 > 0.1 && $0 < 0.9 }.count,
                        firstScale: scales.first ?? 0, lastScale: scales.last ?? 0, ridesZoom: false, maxStep: maxStep)
        s.ridesZoom = Self.rides(s, toOverview: toOverview)
        return s
    }

    /// To the grid: opaque and full size on the first frame, part-faded on
    /// the way, gone and smaller at the end. Back to the page: the same in
    /// reverse, with no jump of its bottom edge while visible. A row removed
    /// when the zoom starts draws no samples.
    static func rides(_ s: Summary, toOverview: Bool) -> Bool {
        guard s.samples >= 3, s.midFades >= 1, s.maxStep <= jumpLimit else { return false }
        if toOverview {
            return s.firstOpacity >= 0.9 && s.lastOpacity <= 0.1 && s.lastScale < s.firstScale - 0.05
        }
        return s.firstOpacity <= 0.1 && s.lastOpacity >= 0.8 && s.lastScale > s.firstScale + 0.05
    }
}
