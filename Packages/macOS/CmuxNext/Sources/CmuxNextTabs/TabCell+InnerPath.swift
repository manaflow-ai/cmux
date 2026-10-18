import CmuxNextDesign
import QuartzCore

// A tab whose width moves (open, close, a reflow) shows its parts as a per-frame relayout would:
// the icon stays at the leading edge, the x rides the trailing edge, the title's fade follows the
// end, and each part shows or hides at the width it does at rest. The main thread lays the parts
// out once per sample of the width path when the move starts (or retargets), and the render server
// plays the samples; nothing runs per frame (perf I7).
extension TabCell {
    /// The keyframes a moving width added to the parts, removed when the path ends.
    struct InnerPath {
        var end: CFTimeInterval
        var layers: [CALayer]
    }

    /// One part's geometry at one sample.
    private struct Part {
        var position: CGPoint
        var size: CGSize
        var opacity: Float
    }

    static let innerKeyPrefix = "tab.inner."

    /// Re-times the parts to the width path from `now` to `end` (every strip move on the root's
    /// size summed, `MotionPath`), replacing the keyframes of an earlier path: a move that starts over
    /// a running one, a hover or a selection change mid-move start from what is on screen.
    func retimeInner(_ path: MotionPath, now: CFTimeInterval, end: CFTimeInterval) {
        titleFade.stopMarquee(animated: false)
        // What shows on screen now (before this layout): the start of the path as the user sees it.
        // The first sample is laid out in the new state (a tab that lost its selection has no x
        // there), so it is not the start form.
        let shownNow = Set((layer.sublayers ?? []).filter { ($0.presentation() ?? $0).opacity > 0.001 }.map(ObjectIdentifier.init))
        let times = MotionPath.times(from: now, to: end, count: MotionPath.sampleCount(seconds: end - now))
        let modelWidth = layer.bounds.width
        // Samples memoized by device pixel: a tab that shrinks a few points lays out a few times.
        var byPixel: [Int: (parts: [ObjectIdentifier: Part], title: TitleFade.Sample?, form: TabChromeVisibility)] = [:]
        var order: [CALayer] = []
        var known: Set<ObjectIdentifier> = []
        var samples: [(parts: [ObjectIdentifier: Part], title: TitleFade.Sample?, form: TabChromeVisibility)] = []
        func record() -> (parts: [ObjectIdentifier: Part], title: TitleFade.Sample?, form: TabChromeVisibility) {
            var parts: [ObjectIdentifier: Part] = [:]
            for part in layer.sublayers ?? [] {
                let id = ObjectIdentifier(part)
                if known.insert(id).inserted { order.append(part) }
                parts[id] = Part(position: part.position, size: part.bounds.size, opacity: part.opacity)
            }
            return (parts, pathTitle, visibility)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, time) in times.enumerated() {
            let width = index == times.count - 1 ? modelWidth : max(0, path.value(at: time).x)
            let key = Int((width * scale).rounded())
            if let sample = byPixel[key] {
                samples.append(sample)
                continue
            }
            layoutParts(slotWidth: CGFloat(key) / scale, onPath: true)
            let sample = record()
            byPixel[key] = sample
            samples.append(sample)
        }
        // The model values: the parts at the target width (the last sample's).
        layoutParts(slotWidth: modelWidth, onPath: true)
        removeInnerKeyframes()
        // Where the parts change form (the x or the title shows or hides, the content centers, the title
        // starts to clip), they jump at the next sample's time as a relayout per frame does; between, they
        // move with the width.
        let steps = Set(samples.indices.dropLast().filter { index in
            samples[index].form != samples[index + 1].form
                || samples[index].title?.geometry.isTruncated != samples[index + 1].title?.geometry.isTruncated
        })
        for part in order where part !== titleLayer {
            let id = ObjectIdentifier(part)
            // A part made at a later sample shows nothing before it.
            let first = samples.lazy.compactMap { $0.parts[id] }.first ?? Part(position: part.position, size: part.bounds.size, opacity: 0)
            var values = samples.map { $0.parts[id] ?? Part(position: first.position, size: first.size, opacity: 0) }
            // A part's visibility changes at most once on the path: shown now and at the end, it
            // stays shown; hidden now and at the end, it stays hidden. A form that fits only between
            // the ends (the x leaves before the width does; the selected tab shows its x before its
            // icon fits beside it) is a transient of the sampling, not a state to show.
            if let end = values.last?.opacity, shownNow.contains(id) == (end > 0.001) {
                for index in values.indices { values[index].opacity = end }
            }
            addKeyframes(values, times: times, steps: steps, to: part)
        }
        // The title shows where its samples have it, but never only between the ends: a crowded tab
        // that loses its selection drops its x at once, and the room fits a few letters of the title
        // for a few samples before the width takes them (a flash, a motion reversal). Its geometry is
        // the fade's (`TitleFade.follow`), so a title shown at either end fades with the width.
        let titleHidden = !shownNow.contains(ObjectIdentifier(titleLayer)) && samples.last?.title == nil
        let titles: [TitleFade.Sample?] = titleHidden ? samples.map { _ in nil } : samples.map(\.title)
        let titleShown = titles.map { $0 != nil }
        if titleShown.contains(true), titleShown.contains(false),
           let animation = MotionPath.keyframes("opacity", values: titleShown.map { NSNumber(value: $0 ? 1 : 0) }, times: times, on: titleLayer, discrete: true) {
            titleLayer.add(animation, forKey: Self.innerKeyPrefix + "opacity")
        }
        titleFade.follow(titles, times: times, steps: steps)
        innerPath = InnerPath(end: end, layers: order)
    }

    /// The path ended or was cut (a cancelled move, a width set at once): the keyframes come off.
    func endInnerPath() {
        guard innerPath != nil else { return }
        removeInnerKeyframes()
        titleFade.stopFollowing()
        innerPath = nil
    }

    private func removeInnerKeyframes() {
        for part in innerPath?.layers ?? [] {
            for key in part.animationKeys() ?? [] where key.hasPrefix(Self.innerKeyPrefix) { part.removeAnimation(forKey: key) }
        }
    }

    /// Keyframes of each value that changes along the path (geometry linear between frames, opacity
    /// held until the next frame, as a relayout per frame shows it).
    private func addKeyframes(_ values: [Part], times: [CFTimeInterval], steps: Set<Int>, to part: CALayer) {
        func varies<T>(_ read: (Part) -> T, _ differ: (T, T) -> Bool) -> Bool {
            guard let first = values.first.map(read) else { return false }
            return values.contains { differ(read($0), first) }
        }
        if varies({ $0.position }, { abs($0.x - $1.x) > 0.01 || abs($0.y - $1.y) > 0.01 }),
           let animation = MotionPath.keyframes("position", values: values.map { NSValue(point: $0.position) }, times: times, on: part, steps: steps) {
            part.add(animation, forKey: Self.innerKeyPrefix + "position")
        }
        if varies({ $0.size }, { abs($0.width - $1.width) > 0.01 || abs($0.height - $1.height) > 0.01 }),
           let animation = MotionPath.keyframes("bounds.size", values: values.map { NSValue(size: $0.size) }, times: times, on: part, steps: steps) {
            part.add(animation, forKey: Self.innerKeyPrefix + "size")
        }
        if varies({ $0.opacity }, { abs($0 - $1) > 0.001 }),
           let animation = MotionPath.keyframes("opacity", values: values.map { NSNumber(value: $0.opacity) }, times: times, on: part, discrete: true) {
            part.add(animation, forKey: Self.innerKeyPrefix + "opacity")
        }
    }
}
