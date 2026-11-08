#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// ZOOM VARIANTS 7 (fork only, never merged): on the Z4 zoom out (film G4P K6, press 7, lead watched
/// /work/tmp/zv6-sheets/v3-g4p-k6-press7-out.png) the nvim pane's right edge moved only a little for 2 refreshes, then in ONE
/// refresh (+41.4 to +49.7 ms) jumped from near full width to its final half width, where a K6 curve is at about 25%.
/// The swap to the live pane when its frame at the new grid lands (ZOOM VARIANTS 6) showed the live pane at its final
/// size at once: the pane's text left the curve. What shows of the zoomed pane must follow the curve in every refresh:
/// no step larger than the curve's own step plus 1 pt, wherever the new frame lands.
@MainActor
@Suite(.closesItsWindows)
struct FilmZoomZ4CurveTests {
    /// `value` as numbers: an opacity, a translation (tx, ty) or a rectangle path's box (minX, minY, maxX, maxY).
    static func numbers(_ value: Any?) -> [Double] {
        guard let value else { return [] }
        if let number = value as? NSNumber { return [number.doubleValue] }
        if let wrapped = value as? NSValue {
            let transform = wrapped.caTransform3DValue
            return [Double(transform.m41), Double(transform.m42)]
        }
        let object = value as AnyObject
        guard CFGetTypeID(object) == CGPath.typeID, let path = value as? CGPath else { return [] }
        let box = path.boundingBox
        return [box.minX, box.minY, box.maxX, box.maxY].map(Double.init)
    }

    /// What `layer` shows for `keyPath` at media time `time`: its animation's value then (a keyframe or basic animation,
    /// linear or discrete), else the model value. An animation not yet committed (begin 0) starts at `begin`.
    static func value(_ layer: CALayer, _ keyPath: String, at time: CFTimeInterval, begin: CFTimeInterval) -> [Double] {
        let model = numbers(layer.value(forKeyPath: keyPath))
        guard let animation = layer.animation(forKey: keyPath) as? CAPropertyAnimation, animation.duration > 0 else { return model }
        let local = time - (animation.beginTime > 0 ? animation.beginTime : begin)
        guard local >= 0, local < animation.duration else { return model }
        let at = local / animation.duration
        if let basic = animation as? CABasicAnimation {
            let from = numbers(basic.fromValue), to = numbers(basic.toValue)
            guard from.count == to.count else { return model }
            return zip(from, to).map { $0 + ($1 - $0) * at } // linear: the Z4 springs are key frames, not basic animations
        }
        guard let frames = animation as? CAKeyframeAnimation, let values = frames.values, !values.isEmpty else { return model }
        let times = frames.keyTimes?.map(\.doubleValue) ?? values.indices.map { Double($0) / Double(max(1, values.count - 1)) }
        let index = max(0, (times.lastIndex { $0 <= at } ?? 0))
        if frames.calculationMode == .discrete { return numbers(values[min(index, values.count - 1)]) }
        guard index + 1 < values.count, index + 1 < times.count else { return numbers(values[values.count - 1]) }
        let a = numbers(values[index]), b = numbers(values[index + 1])
        let span = times[index + 1] - times[index]
        let w = span > 0 ? (at - times[index]) / span : 1
        return zip(a, b).map { $0 + ($1 - $0) * w }
    }

    static func rect(_ box: [Double]) -> CGRect {
        guard box.count == 4 else { return .null }
        return CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
    }

    @Test(arguments: ["zoom_variant Z4 K6", "zoom_variant Z4 K12"])
    func theZoomOutShowsThePaneOnTheCurveInEveryRefresh(_ variant: String) throws {
        let film = DesignSettings.shared.filmZoom
        defer { DesignSettings.shared.filmZoom = film }
        _ = FilmZoomVariant.select(variant)
        let driver = DesignSettings.shared.filmZoom.driver
        let screen = ZoomKeepsCoveredPanesTests.Screen()
        defer { screen.window.closeAfterTest() }
        let zoomed = try #require(screen.root.context.hosts["p1"])
        zoomed.content.wantsLayer = true
        zoomed.content.layer?.backgroundColor = CGColor(gray: 0.1, alpha: 1)
        let surface = FilmZoomZ4OneTextTests.Landing(frame: zoomed.content.bounds)
        zoomed.content.addSubview(surface)
        screen.show(.leaf("p1"), zoomed: true)
        screen.land()

        screen.show(ZoomKeepsCoveredPanesTests.four, zoomed: false)
        _ = screen.root.advanceFrame(1.0 / 120)
        let container = try #require(screen.screen.layer?.sublayers?.first { $0.name?.hasPrefix("film-zoom-pictures-") == true },
                                     "Z4 zoom out shows the zoomed pane's old picture")
        let picture = try #require(container.sublayers?.first)
        let mask = try #require(container.mask)
        let live = try #require(zoomed.layer)
        let path = try #require(mask.animation(forKey: "path") as? CAKeyframeAnimation, "the frame shrinks on the curve")
        let from = Self.rect(Self.numbers(path.values?.first)), to = Self.rect(Self.numbers(path.values?.last))
        #expect(!from.isNull && !to.isNull && from.width > to.width + 100, "the zoom out's frame shrinks: \(from) -> \(to)")
        let begin = path.beginTime
        let place = live.frame

        /// The pane as it shows at `k` refreshes after the motion's start: the old picture in the shrinking frame while
        /// it shows, else the live pane at its place riding the frame's top-left.
        func shown(_ k: Int) -> CGRect {
            let time = begin + Double(k) / 120
            let opacity = picture.isHidden || container.isHidden ? 0 : (Self.value(picture, "opacity", at: time, begin: begin).first ?? 1)
            if opacity > 0 { return Self.rect(Self.value(mask, "path", at: time, begin: begin)) }
            let move = Self.value(live, "transform", at: time, begin: begin)
            return move.count == 2 ? place.offsetBy(dx: move[0], dy: move[1]) : place
        }
        func curve(_ k: Int) -> CGRect {
            let t = Double(k) / 120
            let p = t >= driver.duration ? 1 : (driver.step(t) ?? 1)
            return CGRect(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
                          width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
        }
        func edges(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.maxX, r.maxY].map(Double.init) }

        // The frame at the new grid lands 3 refreshes into the motion (the films: +41 to +50 ms after the key).
        let lands = 3
        let last = Int((driver.duration * 120).rounded(.up)) + 2
        var seen: [CGRect] = (0 ..< lands).map(shown)
        if let landed = surface.filmFrameLanded {
            surface.filmFrameLanded = nil
            landed()
        }
        seen += (lands ... last).map(shown)

        var off: [String] = []
        for k in 1 ..< seen.count {
            let step = zip(edges(seen[k]), edges(seen[k - 1])).map { abs($0 - $1) }
            let own = zip(edges(curve(k)), edges(curve(k - 1))).map { abs($0 - $1) }
            for (edge, name) in ["minX", "minY", "maxX", "maxY"].enumerated() where step[edge] > own[edge] + 1 {
                off.append("refresh \(k) \(name): \(Int(step[edge])) pt, curve \(Int(own[edge])) pt")
            }
        }
        #expect(off.isEmpty, "the zoomed pane leaves the curve (\(variant)): \(off)")
        let end = try #require(seen.last)
        #expect(abs(end.width - to.width) <= 1 && abs(end.height - to.height) <= 1, "the pane does not end at its place: \(end) vs \(to)")
        let endOpacity = Self.value(picture, "opacity", at: begin + Double(last) / 120, begin: begin).first ?? 1
        #expect(picture.isHidden || endOpacity == 0, "the old picture still shows at the motion's end: the live pane never shows")
    }
}
#endif
