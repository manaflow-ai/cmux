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
        if let from = pinStartForm {
            pinStartForm = nil
            // The width's move began at the change (`TabStripMove.begin`), before this layout: the look's samples start
            // there too, so frame 0 shows the old look and each frame after it the look at the width's progress. From
            // `now` the frames between the begin and this layout would show the new look's model at once.
            return retimePin(path, from: from, now: min(now, path.lastBegin ?? now), end: end)
        }
        // What shows on screen now (before this layout): the start of the path as the user sees it.
        // The first sample is laid out in the new state (a tab that lost its selection has no x
        // there), so it is not the start form.
        let shownNow = Set((layer.sublayers ?? []).filter { ($0.presentation() ?? $0).opacity > 0.001 }.map(ObjectIdentifier.init))
        // On the width move's frame grid, so every drawn frame shows the parts at that frame's width (`frameTimes`).
        let times = MotionPath.frameTimes(from: now, to: end, anchor: path.lastBegin)
        let modelWidth = layer.bounds.width
        // Each sample's width in device pixels; the last is the model width.
        let keys = times.indices.map { index in
            Int(((index == times.count - 1 ? modelWidth : max(0, path.value(at: times[index]).x)) * scale).rounded())
        }
        // The form of every sample, chosen for the whole path before any is laid out: each part
        // changes at most once between what shows now and the rest form at the end.
        let forms: [TabChromeVisibility?] = closingVisibility != nil ? keys.map { _ in nil } : TabChromeVisibility.path(
            widths: keys.map { CGFloat($0) / scale },
            from: shownForm(shownNow),
            isPinned: item.isPinned, isSelected: isSelected, isHovered: isHovered, isClosable: item.isClosable,
            hasStatus: hasStatusMark, style: style, metrics: metrics
        )
        // Samples memoized by device pixel and form: a tab that shrinks a few points lays out a few times.
        struct SampleKey: Hashable { var pixel: Int; var form: TabChromeVisibility? }
        var byPixel: [SampleKey: (parts: [ObjectIdentifier: Part], title: TitleFade.Sample?, form: TabChromeVisibility)] = [:]
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
        for (pixel, form) in zip(keys, forms) {
            let key = SampleKey(pixel: pixel, form: form)
            if let sample = byPixel[key] {
                samples.append(sample)
                continue
            }
            layoutParts(slotWidth: CGFloat(pixel) / scale, onPath: true, form: form)
            let sample = record()
            byPixel[key] = sample
            samples.append(sample)
        }
        // The model values: the parts at the target width (the last sample's, the rest form).
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
            // A part hidden on screen now and at the end stays hidden: a form that fits only between
            // the ends (the x leaves before the width does) is a transient of the sampling.
            if !shownNow.contains(id), values.last?.opacity == 0 { for index in values.indices { values[index].opacity = 0 } }
            addKeyframes(values, times: times, steps: steps, to: part)
        }
        // The title shows where the path's form has it (it shows or hides once); its geometry is the
        // fade's (`TitleFade.follow`), so a title shown at either end fades with the width.
        let titles = samples.map(\.title)
        let titleShown = titles.map { $0 != nil }
        if titleShown.contains(true), titleShown.contains(false),
           let animation = MotionPath.keyframes("opacity", values: titleShown.map { NSNumber(value: $0 ? 1 : 0) }, times: times, on: titleLayer, discrete: true) {
            titleLayer.add(animation, forKey: Self.innerKeyPrefix + "opacity")
        }
        titleFade.follow(titles, times: times, steps: steps)
        innerPath = InnerPath(end: end, layers: order)
    }

    /// A pin or an unpin: the parts go from the look the tab showed (`from`: the title, the icon at the leading inset)
    /// to its new rest look (a pinned tab's centred icon, or back) on the width's own progress, so nothing pops on the
    /// first frame or the last. Each part goes on the width's progress from where the old look put it at the start
    /// width to where the new look rests it at the end width: a part anchored the same way in both looks (the pill,
    /// a trailing x) rides the width exactly as a layout per sample would, and the icon goes straight from the leading
    /// inset to the pinned centre (or back). Blending the two looks at each sample's width instead put the pinned
    /// look's icon at the centre of a still wide tab, so it slid across its own title and back (the TAB-PIN film).
    /// Opacities and the title blend per sample: a part in one look only fades with the width, the title too.
    /// Chromium lays a pinned tab out in its new look at once and lets BoundsAnimator move the bounds; here the look
    /// rides the same tween as the bounds instead (cmux-ad m70: "translate properly").
    private func retimePin(_ path: MotionPath, from: TabChromeVisibility, now: CFTimeInterval, end: CFTimeInterval) {
        let times = MotionPath.frameTimes(from: now, to: end, anchor: path.lastBegin)
        let modelWidth = layer.bounds.width
        let widths = times.indices.map { index in index == times.count - 1 ? modelWidth : max(0, path.value(at: times[index]).x) }
        let startWidth = widths.first ?? modelWidth
        let span = modelWidth - startWidth
        let progress = widths.indices.map { index -> CGFloat in
            guard abs(span) > 0.5 else { return CGFloat(index) / CGFloat(max(1, widths.count - 1)) }
            return min(max((widths[index] - startWidth) / span, 0), 1)
        }
        let to = TabChromeVisibility.resolve(width: modelWidth, isPinned: item.isPinned, isSelected: isSelected, isHovered: isHovered,
                                             isClosable: item.isClosable, hasStatus: hasStatusMark, style: style, metrics: metrics)
        // The start look keeps its parts at every width (only the width moves them).
        let start = from
        var order: [CALayer] = []
        var known: Set<ObjectIdentifier> = []
        func record() -> ([ObjectIdentifier: Part], TitleFade.Sample?) {
            var parts: [ObjectIdentifier: Part] = [:]
            for part in layer.sublayers ?? [] {
                let id = ObjectIdentifier(part)
                if known.insert(id).inserted { order.append(part) }
                parts[id] = Part(position: part.position, size: part.bounds.size, opacity: part.opacity)
            }
            return (parts, pathTitle)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        func snapped(_ width: CGFloat) -> CGFloat { (width * scale).rounded() / scale }
        // The geometry's two ends: the old look at the start width, the new look at rest.
        layoutParts(slotWidth: snapped(startWidth), onPath: true, form: start)
        let (startParts, _) = record()
        layoutParts(slotWidth: snapped(modelWidth), onPath: true, form: to)
        let (endParts, _) = record()
        var samples: [(parts: [ObjectIdentifier: Part], title: TitleFade.Sample?, titleOpacity: Float)] = []
        for (width, p) in zip(widths, progress) {
            let slot = snapped(width)
            layoutParts(slotWidth: slot, onPath: true, form: start)
            let (a, titleA) = record()
            layoutParts(slotWidth: slot, onPath: true, form: to)
            let (b, titleB) = record()
            var blended: [ObjectIdentifier: Part] = [:]
            for id in Set(a.keys).union(b.keys) {
                let pa = a[id], pb = b[id]
                guard let from = startParts[id] ?? pa ?? pb, let target = endParts[id] ?? pb ?? pa else { continue }
                let opacity = (pa?.opacity ?? 0) * Float(1 - p) + (pb?.opacity ?? 0) * Float(p)
                blended[id] = Part(position: CGPoint(x: from.position.x + (target.position.x - from.position.x) * p,
                                                     y: from.position.y + (target.position.y - from.position.y) * p),
                                   size: CGSize(width: from.size.width + (target.size.width - from.size.width) * p,
                                                height: from.size.height + (target.size.height - from.size.height) * p),
                                   opacity: opacity)
            }
            let titleOpacity = Float(titleA == nil ? 0 : 1 - p) + Float(titleB == nil ? 0 : p)
            samples.append((blended, titleA ?? titleB, titleOpacity))
        }
        // The model values: the parts at rest in the new look.
        layoutParts(slotWidth: modelWidth, onPath: true)
        removeInnerKeyframes()
        for part in order where part !== titleLayer {
            let id = ObjectIdentifier(part)
            let first = samples.lazy.compactMap { $0.parts[id] }.first ?? Part(position: part.position, size: part.bounds.size, opacity: 0)
            addKeyframes(samples.map { $0.parts[id] ?? Part(position: first.position, size: first.size, opacity: 0) }, times: times,
                         steps: [], to: part, fades: true)
        }
        let titleOpacities = samples.map(\.titleOpacity)
        if titleOpacities.contains(where: { abs($0 - (titleOpacities.first ?? 0)) > 0.001 }),
           let animation = MotionPath.keyframes("opacity", values: titleOpacities.map { NSNumber(value: $0) }, times: times, on: titleLayer) {
            titleLayer.add(animation, forKey: Self.innerKeyPrefix + "opacity")
        }
        titleFade.follow(samples.map(\.title), times: times, steps: [])
        innerPath = InnerPath(end: end, layers: order)
    }

    /// The form on screen now, from what the parts show (`shown`: the parts whose presentation is
    /// visible): the start of a width path as the user sees it, also mid-way through an earlier path.
    private func shownForm(_ shown: Set<ObjectIdentifier>) -> TabChromeVisibility {
        func on(_ part: CALayer?) -> Bool { part.map { shown.contains(ObjectIdentifier($0)) } ?? false }
        let title = on(titleLayer)
        // A spinner that fades out (`isSpinnerExiting`) no longer stands for the icon.
        return TabChromeVisibility(showsIcon: on(iconLayer) || (!isSpinnerExiting && on(spinnerLayer?.layer)), showsTitle: title,
                                   showsClose: on(closeGlyphLayer), centersContent: !title)
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
    /// `fades`: opacity moves between the samples (a pin's look changing on the width's progress), not held.
    private func addKeyframes(_ values: [Part], times: [CFTimeInterval], steps: Set<Int>, to part: CALayer, fades: Bool = false) {
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
           let animation = MotionPath.keyframes("opacity", values: values.map { NSNumber(value: $0.opacity) }, times: times, on: part, discrete: !fades) {
            part.add(animation, forKey: Self.innerKeyPrefix + "opacity")
        }
    }
}
