#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.new_tab {action: "frame_strip"}` (DEBUG builds): the window as the
/// window server composited it, frame after frame, around one key sent
/// through the real key path (`key`, default `n`, with Command: Cmd-N; `t`
/// for Cmd-T). Frames are read off the main actor back to back for
/// `duration_ms` (default 700) after the key, and some before it.
///
/// A paint-stable opening changes only the content area of the pane that
/// shows the new page (its `contentHost`), and that in one step: every frame
/// outside it equals the frame before the key or the last frame
/// (`intermediate` counts the ones that equal neither), and no frame shows
/// the content area blank, one flat color that was not there before the key (`blank`). PNGs of every frame and
/// one strip (`strip.png`, the frames side by side) go to `dir`.
///
/// `modifiers` (default `["command"]`) sends another chord. In the content area `settled_ms` is the
/// first frame equal to the last for good, `first_change_ms` the first unlike before the key, and
/// `content_intermediate` counts frames equal to neither. The pane's strip (its tabs slide) is left
/// out of those and of `intermediate`; `strip_intermediate` counts its frames equal to neither, and
/// `desync` those where one of strip and content shows the new tab and the other the old one.
@MainActor
enum DebugFrameStrip {
    typealias Frame = WindowFrame

    static func run(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let window = controller.window, window.windowNumber > 0 else { return .object(["error": .string("no window")]) }
        let number = CGWindowID(window.windowNumber)
        let scale = params["scale"]?.doubleValue ?? 0.25
        let duration = params["duration_ms"]?.doubleValue ?? 700
        let tolerance = params["tolerance"]?.doubleValue ?? 0.002
        let dir = params["dir"]?.stringValue ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("frame-strip-\(UUID().uuidString)")
        // The app's bench marks around the key come back with the frames (`spans`, ms from the key).
        BenchSpans.begin()
        let start = ContinuousClock.now
        let recording = Task.detached { await WindowFrame.record(number, scale: scale, from: start, until: 120 + duration) }
        // The key goes in once the recorder has frames from before it.
        let lead = DemandTimer(owner: "debug.frame_strip.lead")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lead.schedule(after: .milliseconds(120)) { @MainActor in done.resume() }
        }
        let sent = DebugKey.send(["key": .string(params["key"]?.stringValue ?? "n"), "modifiers": params["modifiers"] ?? .array([.string("command")]),
                                  "window": .string(controller.state.id)], services: services)
        let sentAt = BenchSpans.ms(.now - start)
        let frames = await recording.value
        let spans = BenchSpans.end()
        guard let first = frames.first, let last = frames.last, let before = frames.last(where: { $0.milliseconds < sentAt }) else {
            return .object(["error": .string("no frames"), "key": sent])
        }
        let content = (controller.content?.focusedPane?.view.contentHost).flatMap { rect(of: $0, window: window, frame: first) }
        // The pane's strip, apart: its own motion (tabs sliding over) is not content.
        let strip = (controller.content?.focusedPane?.view.stripView)
            .flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : rect(of: $0, window: window, frame: first) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var rows: [JSONValue] = []
        var intermediate = 0, blank = 0, contentIntermediate = 0, desync = 0, stripIntermediate = 0
        var settledAt: Double?, firstChange: Double?
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
            rows.append(.object([
                "ms": .number((frame.milliseconds - sentAt).rounded()), "file": .string(name),
                "outside_vs_before": .number(m.outsideBefore), "outside_vs_final": .number(m.outsideFinal), "intermediate": .bool(isIntermediate),
                "blank": .bool(isBlank), "desync": .bool(isDesync), "content_intermediate": .bool(isContentIntermediate),
            ]))
        }
        WindowFrame.writeStrip(frames.filter { $0.milliseconds >= before.milliseconds }, to: (dir as NSString).appendingPathComponent("strip.png"))
        return .object([
            "key": sent, "dir": .string(dir), "frames": .array(rows), "intermediate": .number(Double(intermediate)),
            "blank": .number(Double(blank)), "frame_count": .number(Double(rows.count)),
            "content_intermediate": .number(Double(contentIntermediate)), "desync": .number(Double(desync)),
            "strip_intermediate": .number(Double(stripIntermediate)),
            "settled_ms": settledAt.map { .number($0.rounded()) } ?? .null, "first_change_ms": firstChange.map { .number($0.rounded()) } ?? .null,
            "spans": .array(spans.map { .object(["name": .string($0.name), "ms": .number(($0.start - sentAt).rounded()), "duration_ms": .number($0.milliseconds)]) }),
            "mean_interval_ms": .number(frames.count > 1 ? (last.milliseconds - first.milliseconds) / Double(frames.count - 1) : 0),
        ])
    }

    /// `host`'s bounds in `frame` pixels (top-left origin).
    private static func rect(of host: NSView, window: NSWindow, frame: Frame) -> CGRect? {
        guard host.window === window,
              let windowHeight = window.contentView?.superview?.bounds.height ?? window.contentView?.bounds.height
        else { return nil }
        let rect = host.convert(host.bounds, to: nil)
        let sx = Double(frame.width) / window.frame.width, sy = Double(frame.height) / windowHeight
        return CGRect(x: rect.minX * sx, y: (windowHeight - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
    }
}
#endif
