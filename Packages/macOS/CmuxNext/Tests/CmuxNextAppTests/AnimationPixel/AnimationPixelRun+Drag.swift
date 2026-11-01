import AppKit
@testable import CmuxNextLayout
import Foundation
import QuartzCore
import Testing

@available(macOS 14.4, *)
extension AnimationPixelRun {
    /// Drags the handle `kind` along `path` (``PointerDriver``) and judges the drag's frames along
    /// `axis`, then the frame after the release.
    ///
    /// While pressed, a divider shows its lit band (DividerGlowBand: a 2 pt core and a 3 pt
    /// blurred halo), soft by design, so the band is a free zone: its pixels are not named, it is
    /// bounded by the exact colors on each side, and its width never changes (it moves rigidly).
    /// Every boundary in `moving` (indices into the scanline's boundaries, which follow its
    /// elements) must follow the pointer 1:1 in points, within 1 device pixel, one display refresh
    /// at a time with no dropped frame; the others must stay. After the release the band goes and
    /// the last frame must be the layout's final geometry exactly.
    func judgeDrag(_ kind: DividerHandleView.Kind, axis: Axis, path: [Double], moving: (Int, [ScanlineElement]) -> Bool) async throws -> [String] {
        let window = fixture.window, scale = fixture.scale
        let screen = try #require(fixture.screen)
        let handle = try #require(screen.dividerViews[kind], "no handle \(kind)")
        let width = Int((window.frame.width * scale).rounded()), height = Int((window.frame.height * scale).rounded())
        let rowY = height / 2, columnX = width / 2, length = axis == .row ? width : height
        let position = CGFloat(axis == .row ? rowY : columnX) / scale
        let line: (WindowFrameStream.Image) -> [UInt32] = { image in
            axis == .row ? (0..<image.width).map { image.pixel(x: $0, y: rowY) } : (0..<image.height).map { image.pixel(x: columnX, y: $0) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let stream = WindowFrameStream(rowY: rowY, columnX: columnX)
        try await stream.start(window: window)
        try await Task.sleep(for: .milliseconds(300))
        guard let rest = stream.lastImage else {
            await stream.stop()
            try stream.requireUninterrupted()
            throw Failure(description: "\(name): ScreenCaptureKit gave no frame of the window at rest")
        }
        // The resting colors: panes, divider lines, gaps.
        let geometry = elements(screen, axis: axis, at: position, length: length)
        var palette = ScanlinePalette()
        for element in geometry {
            let center = Int(((element.start + element.end) / 2).rounded(.down))
            try palette.learn(element.color, axis == .row ? rest.pixel(x: center, y: rowY) : rest.pixel(x: columnX, y: center))
        }
        let driver = PointerDriver(handle: handle, window: window, vertical: axis == .column, path: path)
        driver.press()
        // The press lights the band through Motion.feedback; let its fade end.
        try await Task.sleep(for: .milliseconds(400))
        guard let pressed = stream.lastImage else { throw Failure(description: "\(name): no frame of the pressed handle") }
        let label = "divider:\(kind.geometryLabel)"
        let tracked = try bandElements(geometry, band: label, line: line(pressed), palette: palette)
        let sampler = PresentationSampler(window: window, views: fixture.sampledViews)
        let trigger = CACurrentMediaTime()
        try await driver.drag()
        try await fixture.settle()
        try await Task.sleep(for: .milliseconds(300))
        sampler.stop()
        await stream.stop()
        try stream.requireUninterrupted()

        let release = driver.releaseTime ?? .infinity
        let moves = driver.moves, final = moves.last?.offset ?? 0
        let gains = tracked.dropLast().indices.map { moving($0, tracked) ? Double(scale) : 0 }
        func shift(_ boundary: Int) -> Double { boundary >= 0 && boundary < gains.count ? gains[boundary] * final : 0 }
        var judged: [ScanlineElement] = []
        for (index, element) in tracked.enumerated() {
            judged.append(ScanlineElement(label: element.label, before: element.before,
                                          after: (start: element.before.start + shift(index - 1), end: element.before.end + shift(index)),
                                          exactLength: element.exactLength, free: element.free))
        }
        let starts: [Double] = judged.dropLast().map { $0.before.end }
        let oracle = ScanlineOracle(name: "pointer path (\(moves.count) moves)", boundaries: { elapsed in
            let offset = moves.last { $0.time <= trigger + elapsed }?.offset ?? 0
            return zip(starts, gains).map { $0 + $1 * offset }
        }, originWindow: 0...5 * fixture.display.refreshPeriod, overshoot: [Double](repeating: 0, count: starts.count))
        let judge = ScanlineJudge(oracle: oracle, elements: judged, trigger: trigger, period: fixture.display.refreshPeriod)
        let captured = stream.captured
        let timing = Self.retime(captured.map { (time: $0.time, line: axis == .row ? $0.row : $0.column) }, samples: sampler.samples,
                                 palette: palette, axis: axis, position: position, windowHeight: window.frame.height, scale: scale,
                                 length: length, period: fixture.display.refreshPeriod, trigger: trigger, adjust: bandAdjust(geometry, tracked))
        let all = timing.frames
        // The drag's frames: those shown before the release was sent (the band goes with the release).
        let verdict = judge.judge(all.filter { $0.time < release }, palette: palette, moves: true)
        var failures = timing.failures + verdict.failures
        failures += sampler.gridFailures(from: trigger - fixture.display.refreshPeriod, scale: scale)
        for gap in sampler.missedRefreshes(from: trigger, to: release, period: fixture.display.refreshPeriod) {
            failures.append("the main thread missed a display refresh in the drag: \(String(format: "%.1f", gap)) ms between ticks")
        }
        // After the release: the resting look again, at the layout's final geometry exactly.
        let landed = elements(screen, axis: axis, at: position, length: length)
        if let last = all.last {
            let runs = palette.runs(last.line)
            let expected = landed.dropLast().map { Int($0.end.rounded()) }
            if runs.map(\.name) != landed.map(\.color) || Array(runs.dropLast().map(\.end)) != expected {
                failures.append("after the release the last frame reads \(runs), the final layout is "
                    + "\(landed.map { "\($0.label)[\($0.start)..<\($0.end)]" })")
            }
        }
        print("ANIMATION-PIXEL \(name): scale \(Int(scale))x, \(window.effectiveAppearance.name.rawValue), \(all.count) complete and "
            + "\(stream.idleFrames) idle frames, \(moves.count) pointer moves, frames timed by the committing tick "
            + "(\(timing.matched) matched), \(failures.count) failures")
        print("ANIMATION-PIXEL \(name): pointer moves (ms after the first, offset pt): "
            + moves.map { "\(AnimationPixelRun.ms($0.time - trigger)):\(Int($0.offset))" }.joined(separator: " "))
        for line in verdict.report { print("ANIMATION-PIXEL \(name): \(line)") }
        for failure in failures.prefix(40) { print("ANIMATION-PIXEL \(name): FAIL \(failure)") }
        return failures
    }

    /// How far the pressed band moves the exact-color edges of the panes beside it from their host
    /// edges (measured on the pressed frame, constant while the band moves rigidly).
    private func bandAdjust(_ geometry: [ScanlineSpan], _ tracked: [ScanlineElement]) -> [String: [Int]] {
        guard let index = tracked.firstIndex(where: \.free), index > 0, index + 1 < tracked.count else { return [:] }
        var adjust: [String: [Int]] = [:]
        let before = tracked[index - 1], after = tracked[index + 1]
        if let host = geometry.first(where: { $0.label == before.label }) {
            adjust[before.label] = [0, Int((before.before.end - host.end).rounded())]
        }
        if let host = geometry.first(where: { $0.label == after.label }) {
            adjust[after.label] = [Int((after.before.start - host.start).rounded()), 0]
        }
        return adjust
    }

    /// The scanline's elements with the pressed divider `band` as a free zone measured on the
    /// pressed frame: from the last pixel of the element before it to the first of the element after.
    private func bandElements(_ geometry: [ScanlineSpan], band: String,
                              line: [UInt32], palette: ScanlinePalette) throws -> [ScanlineElement] {
        guard let index = geometry.firstIndex(where: { $0.label == band }), index > 0, index + 1 < geometry.count else {
            throw Failure(description: "\(name): the scanline does not cross \(band) between two elements: \(geometry.map(\.label))")
        }
        let runs = palette.runs(line)
        let before = geometry[index - 1].color, after = geometry[index + 1].color
        let center = (geometry[index].start + geometry[index].end) / 2
        guard let left = runs.last(where: { $0.label == before && Double($0.start) < center }),
              let right = runs.first(where: { $0.label == after && Double($0.end) > center }), left.end <= right.start else {
            throw Failure(description: "\(name): the pressed band around \(band) is not bounded by \(before) and \(after): \(runs)")
        }
        var zoned: [ScanlineElement] = []
        for (position, element) in geometry.enumerated() {
            let span: (start: Double, end: Double)
            switch position {
            case index - 1: span = (start: element.start, end: Double(left.end))
            case index: span = (start: Double(left.end), end: Double(right.start))
            case index + 1: span = (start: Double(right.start), end: element.end)
            default: span = (start: element.start, end: element.end)
            }
            zoned.append(ScanlineElement(label: element.label, before: span, after: span,
                                            exactLength: position == index ? right.start - left.end : element.exactLength,
                                            free: position == index))
        }
        return zoned
    }
}

extension DividerHandleView.Kind {
    /// The label ``AnimationPixelRun`` gives this handle's line on a scanline.
    var geometryLabel: String {
        switch self {
        case let .split(id): id.rawValue
        case let .columnEdge(id): "edge:\(id.rawValue)"
        case let .rowEdge(column, upper): "row:\(column.rawValue):\(upper.rawValue)"
        }
    }
}
