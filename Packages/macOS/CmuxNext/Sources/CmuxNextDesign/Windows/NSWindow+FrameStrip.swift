#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import Foundation

extension NSWindow {
    /// The report fields (Foundation values) of `frames` recorded from this window, the key sent at
    /// `sentAt` ms (`sentTime` in media time); nil when no frame came before the key.
    ///
    /// The analysis half of `debug.new_tab {action: "frame_strip"}` (DEBUG builds): the app sends the
    /// key or gesture and records the window (``WindowFrame``); this compares the frames and writes them.
    ///
    /// A paint-stable opening changes only the content area of the pane that shows the new page (its
    /// `contentHost`), and that in one step: every frame outside it equals the frame before the key or
    /// the last frame (`intermediate` counts the ones that equal neither), and no frame shows the content
    /// area blank, one flat color that was not there before the key (`blank`). PNGs of every frame and one
    /// strip (`strip.png`, the frames side by side) go to `dir`.
    ///
    /// In the content area `settled_ms` is the first frame equal to the last for good, `first_change_ms`
    /// the first unlike before the key, and `content_intermediate` counts frames equal to neither. The
    /// pane's strip (its tabs slide) is left out of those and of `intermediate`; `strip_intermediate`
    /// counts its frames equal to neither, and `desync` those where one of strip and content shows the
    /// new tab and the other the old one. Motion proof knobs and fields: ``MotionFrameProgress``.
    public func frameStripReport(_ frames: [WindowFrame], sentAt: Double, sentTime: CFTimeInterval,
                                 content contentHost: NSView?, strip stripView: NSView?, tolerance: Double, jump: Double?,
                                 dir: String) async -> [String: Any]? {
        guard let first = frames.first, let last = frames.last, let before = frames.last(where: { $0.milliseconds < sentAt }) else { return nil }
        let content = contentHost.flatMap { pixelRect(of: $0, frame: first) }
        // The pane's strip, apart: its own motion (tabs sliding over) is not content.
        let strip = stripView.flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : pixelRect(of: $0, frame: first) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        var intermediate = 0, blank = 0, contentIntermediate = 0, desync = 0, stripIntermediate = 0
        var settledAt: Double?, firstChange: Double?
        var progress = MotionFrameProgress(jump: jump)
        let shown = frames.firstIndex { $0.milliseconds >= before.milliseconds } ?? frames.endIndex
        // Off the main actor: six comparisons a frame stalled it past the watchdog in a Debug build.
        let measures = await WindowFrame.measure(Array(frames[shown...]), before: before, last: last, content: content, strip: strip)
        for (offset, m) in measures.enumerated() {
            let index = shown + offset, frame = frames[index]
            let (insideBefore, insideFinal, stripBefore, stripFinal) = (m.insideBefore, m.insideFinal, m.stripBefore, m.stripFinal)
            let isIntermediate = m.outsideBefore > tolerance && m.outsideFinal > tolerance
            // One of the strip and the content at the new tab, the other still at the old one (L4).
            let isDesync = strip != nil
                && ((stripFinal <= tolerance && stripBefore > tolerance && insideBefore <= tolerance && insideFinal > tolerance)
                    || (insideFinal <= tolerance && insideBefore > tolerance && stripBefore <= tolerance && stripFinal > tolerance))
            // Neither the content before the key nor the settled one; blank: flat too (an empty terminal is flat).
            let isBlank = content != nil && m.flatness > 0.995 && insideBefore > tolerance && insideFinal > tolerance
            let isContentIntermediate = frame.milliseconds > sentAt && insideBefore > tolerance && insideFinal > tolerance
            if isIntermediate { intermediate += 1 }
            progress.add(outsideBefore: m.outsideBefore, outsideFinal: m.outsideFinal)
            if isBlank { blank += 1 }
            if isContentIntermediate { contentIntermediate += 1 }
            if frame.milliseconds > sentAt {
                if stripBefore > tolerance && stripFinal > tolerance { stripIntermediate += 1 }
                if isDesync { desync += 1 }
                if firstChange == nil, insideBefore > tolerance { firstChange = frame.milliseconds - sentAt }
                if insideFinal > tolerance { settledAt = nil } else if settledAt == nil { settledAt = frame.milliseconds - sentAt }
            }
            let name = String(format: "frame-%03d.png", index)
            frame.write(to: (dir as NSString).appendingPathComponent(name))
            rows.append([
                "ms": (frame.milliseconds - sentAt).rounded(), "file": name,
                "outside_vs_before": m.outsideBefore, "outside_vs_final": m.outsideFinal, "intermediate": isIntermediate,
                "blank": isBlank, "desync": isDesync, "content_intermediate": isContentIntermediate,
            ])
        }
        WindowFrame.writeStrip(frames.filter { $0.milliseconds >= before.milliseconds }, to: (dir as NSString).appendingPathComponent("strip.png"))
        let motion = progress.fields(moving: intermediate, tabs: MotionTravelSummary("tabs.travel", after: sentTime))
        let report: [String: Any] = [
            "dir": dir, "frames": rows, "intermediate": Double(intermediate), "blank": Double(blank), "frame_count": Double(rows.count),
            "content_intermediate": Double(contentIntermediate), "desync": Double(desync), "strip_intermediate": Double(stripIntermediate),
            "settled_ms": settledAt.map { $0.rounded() as Any } ?? NSNull(), "first_change_ms": firstChange.map { $0.rounded() as Any } ?? NSNull(),
            "mean_interval_ms": frames.count > 1 ? (last.milliseconds - first.milliseconds) / Double(frames.count - 1) : 0,
        ]
        return report.merging(motion.mapValues { $0 as Any }) { first, _ in first }
    }

    /// `host`'s rect as fractions of the window's captured image (top-left origin), for `WindowFrame.record(crop:)`.
    public func unitRect(of host: NSView) -> CGRect? {
        guard host.window === self, frame.width > 0,
              let windowHeight = contentView?.superview?.bounds.height ?? contentView?.bounds.height, windowHeight > 0
        else { return nil }
        let rect = host.convert(host.bounds, to: nil)
        return CGRect(x: rect.minX / frame.width, y: (windowHeight - rect.maxY) / windowHeight, width: rect.width / frame.width, height: rect.height / windowHeight)
    }

    /// `host`'s bounds in `frame` pixels (top-left origin).
    private func pixelRect(of host: NSView, frame: WindowFrame) -> CGRect? {
        guard host.window === self,
              let windowHeight = contentView?.superview?.bounds.height ?? contentView?.bounds.height
        else { return nil }
        let rect = host.convert(host.bounds, to: nil)
        let sx = Double(frame.width) / self.frame.width, sy = Double(frame.height) / windowHeight
        return CGRect(x: rect.minX * sx, y: (windowHeight - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
    }
}
#endif
