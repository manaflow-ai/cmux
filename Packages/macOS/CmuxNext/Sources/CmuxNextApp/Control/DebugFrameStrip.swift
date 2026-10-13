#if DEBUG
import AppKit
import CmuxNextActions
import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import ImageIO
import UniformTypeIdentifiers

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
/// `perform` runs that action by name instead of a key (`target`: a tab id).
/// `modifiers` (default `["command"]`) sends another chord, for tab switches
/// and closes (Control-Tab, Command-Shift-], Command-W). Inside the content
/// area, `settled_ms` is the first frame from which it equals the last frame
/// for good, `first_change_ms` the first that differs from before the key,
/// and `content_intermediate` counts the frames equal to neither: a loading,
/// partly drawn or reflowing page between the two tabs. The pane's strip is
/// left out of those (its tabs slide on a close); `desync` counts the frames
/// where one of the strip and the content shows the new tab and the other the
/// old one. `region: "workspace"` measures the whole workspace area instead of
/// the focused pane's.
@MainActor
enum DebugFrameStrip {
    nonisolated struct Frame: Sendable {
        var milliseconds: Double
        var width: Int
        var height: Int
        var pixels: [UInt8]
    }

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
        let recording = Task.detached { await record(number, scale: scale, from: start, until: 120 + duration) }
        // The key goes in once the recorder has frames from before it.
        let lead = DemandTimer(owner: "debug.frame_strip.lead")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lead.schedule(after: .milliseconds(120)) { @MainActor in done.resume() }
        }
        let sent: JSONValue
        if let action = params["perform"]?.stringValue {
            // The action a key runs, by name (`nextSurface`, `nextSidebarTab`), whatever the keymap binds.
            let target = params["target"]?.stringValue.map { ActionTargetRef(kind: .tab, id: $0) }
            let ran = services.registry.perform(ActionID(rawValue: action), invocation: ActionInvocation(target: target, origin: .user))
            sent = .object(["action": .string(action), "ran": .bool(ran)])
        } else {
            let modifiers = params["modifiers"] ?? .array([.string("command")])
            sent = DebugKey.send(["key": .string(params["key"]?.stringValue ?? "n"), "modifiers": modifiers,
                                  "window": .string(controller.state.id)], services: services)
        }
        let sentAt = BenchSpans.ms(.now - start)
        let frames = await recording.value
        let spans = BenchSpans.end()
        guard let first = frames.first, let last = frames.last, let before = frames.last(where: { $0.milliseconds < sentAt }) else {
            return .object(["error": .string("no frames"), "key": sent])
        }
        let workspace = params["region"]?.stringValue == "workspace"
        let content = contentRect(controller, window: window, frame: first, workspace: workspace)
        // The pane's strip, apart: its own motion (a close's tabs sliding over) is not content.
        let strip = workspace ? nil : (controller.content?.focusedPane?.view.stripView)
            .flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : rect(of: $0, window: window, frame: first) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var rows: [JSONValue] = []
        var intermediate = 0, blank = 0, contentIntermediate = 0, desync = 0
        var settledAt: Double?, firstChange: Double?
        for (index, frame) in frames.enumerated() where frame.milliseconds >= before.milliseconds {
            let outsideBefore = difference(frame, before, excluding: content)
            let outsideFinal = difference(frame, last, excluding: content)
            let isIntermediate = outsideBefore > tolerance && outsideFinal > tolerance
            let insideBefore = content.map { difference(frame, before, excluding: strip, within: $0) } ?? 0
            let insideFinal = content.map { difference(frame, last, excluding: strip, within: $0) } ?? 0
            let stripBefore = strip.map { difference(frame, before, within: $0) } ?? 0
            let stripFinal = strip.map { difference(frame, last, within: $0) } ?? 0
            // One of the strip and the content at the new tab, the other still at the old one (L4).
            let isDesync = strip != nil
                && ((stripFinal <= tolerance && stripBefore > tolerance && insideBefore <= tolerance && insideFinal > tolerance)
                    || (insideFinal <= tolerance && insideBefore > tolerance && stripBefore <= tolerance && stripFinal > tolerance))
            // Flat, and neither the content from before the key nor the settled one (an empty terminal is flat too).
            let isBlank = content.map { flatness(frame, in: $0) > 0.995 && insideBefore > tolerance && insideFinal > tolerance } ?? false
            if isIntermediate { intermediate += 1 }
            if isBlank { blank += 1 }
            if frame.milliseconds > sentAt {
                if insideBefore > tolerance && insideFinal > tolerance { contentIntermediate += 1 }
                if isDesync { desync += 1 }
                if firstChange == nil, insideBefore > tolerance { firstChange = frame.milliseconds - sentAt }
                if insideFinal > tolerance { settledAt = nil } else if settledAt == nil { settledAt = frame.milliseconds - sentAt }
            }
            let name = String(format: "frame-%03d.png", index)
            write(frame, to: (dir as NSString).appendingPathComponent(name))
            rows.append(.object([
                "ms": .number((frame.milliseconds - sentAt).rounded()), "file": .string(name),
                "outside_vs_before": .number(outsideBefore), "outside_vs_final": .number(outsideFinal),
                "intermediate": .bool(isIntermediate), "blank": .bool(isBlank), "desync": .bool(isDesync),
            ]))
        }
        writeStrip(frames.filter { $0.milliseconds >= before.milliseconds }, to: (dir as NSString).appendingPathComponent("strip.png"))
        return .object([
            "key": sent, "dir": .string(dir), "frames": .array(rows), "intermediate": .number(Double(intermediate)),
            "blank": .number(Double(blank)), "frame_count": .number(Double(rows.count)),
            "content_intermediate": .number(Double(contentIntermediate)), "desync": .number(Double(desync)),
            "settled_ms": settledAt.map { .number($0.rounded()) } ?? .null, "first_change_ms": firstChange.map { .number($0.rounded()) } ?? .null,
            "spans": .array(spans.map { .object(["name": .string($0.name), "ms": .number(($0.start - sentAt).rounded()), "duration_ms": .number($0.milliseconds)]) }),
            "mean_interval_ms": .number(frames.count > 1 ? (last.milliseconds - first.milliseconds) / Double(frames.count - 1) : 0),
        ])
    }

    /// The focused pane's content area in `frame` pixels (top-left origin), once the key opened its page;
    /// with `workspace`, the whole workspace area beside the sidebar (a sidebar item switch, `region: "workspace"`).
    private static func contentRect(_ controller: WindowController, window: NSWindow, frame: Frame, workspace: Bool) -> CGRect? {
        let view: NSView? = workspace ? controller.content?.layoutView : controller.content?.focusedPane?.view.contentHost
        return view.flatMap { rect(of: $0, window: window, frame: frame) }
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

    /// Reads the window's composited image back to back until `until` ms after `start`.
    @concurrent nonisolated static func record(_ window: CGWindowID, scale: Double, from start: ContinuousClock.Instant,
                                               until: Double) async -> [Frame] {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        var frames: [Frame] = []
        // Each pass reads one image (a window server round trip); the loop ends at the deadline.
        while BenchSpans.ms(.now - start) < until {
            // kCGWindowListOptionIncludingWindow; kCGWindowImageBoundsIgnoreFraming | NominalResolution.
            guard let image = create(.null, 1 << 3, window, (1 << 0) | (1 << 9))?.takeRetainedValue() else { break }
            let at = BenchSpans.ms(.now - start)
            if let frame = downscale(image, scale: scale, at: at) { frames.append(frame) }
        }
        return frames
    }

    nonisolated static func downscale(_ image: CGImage, scale: Double, at milliseconds: Double) -> Frame? {
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Frame(milliseconds: milliseconds, width: width, height: height, pixels: pixels) : nil
    }

    /// The share of pixels outside `excluded` (or only those `within` it) whose color differs by more than a small step.
    nonisolated static func difference(_ a: Frame, _ b: Frame, excluding excluded: CGRect? = nil, within: CGRect? = nil) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        var differing = 0, counted = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                // Rows run bottom-up in the bitmap; the rects are top-left based.
                let point = CGPoint(x: Double(x) + 0.5, y: Double(a.height - 1 - y) + 0.5)
                if let excluded, excluded.contains(point) { continue }
                if let within, !within.contains(point) { continue }
                let i = (y * a.width + x) * 4
                counted += 1
                if max(abs(Int(a.pixels[i]) - Int(b.pixels[i])), abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])),
                       abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))) > 24 { differing += 1 }
            }
        }
        return counted == 0 ? 0 : Double(differing) / Double(counted)
    }

    /// The share of `rect`'s pixels within a small step of its most common color.
    nonisolated static func flatness(_ frame: Frame, in rect: CGRect) -> Double {
        var counts: [UInt32: Int] = [:], total = 0
        var samples: [(Int, Int, Int)] = []
        for y in 0..<frame.height {
            for x in 0..<frame.width where rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(frame.height - 1 - y) + 0.5)) {
                let i = (y * frame.width + x) * 4
                let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
                counts[UInt32(r >> 3) << 10 | UInt32(g >> 3) << 5 | UInt32(b >> 3), default: 0] += 1
                samples.append((r, g, b))
                total += 1
            }
        }
        guard total > 0, let mode = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let r = Int(mode >> 10) << 3, g = Int((mode >> 5) & 31) << 3, b = Int(mode & 31) << 3
        let near = samples.filter { abs($0.0 - r) <= 12 && abs($0.1 - g) <= 12 && abs($0.2 - b) <= 12 }.count
        return Double(near) / Double(total)
    }

    private static func image(_ frame: Frame) -> CGImage? {
        let data = Data(frame.pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func write(_ frame: Frame, to path: String) {
        guard let image = image(frame) else { return }
        writePNG(image, to: path)
    }

    /// The frames side by side, one gap apart, at their recorded size.
    private static func writeStrip(_ frames: [Frame], to path: String) {
        guard let first = frames.first else { return }
        let gap = 4, width = frames.count * (first.width + gap) - gap
        guard let context = CGContext(data: nil, width: width, height: first.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for (index, frame) in frames.enumerated() {
            guard let image = image(frame) else { continue }
            context.draw(image, in: CGRect(x: index * (first.width + gap), y: 0, width: frame.width, height: frame.height))
        }
        if let strip = context.makeImage() { writePNG(strip, to: path) }
    }

    private static func writePNG(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
