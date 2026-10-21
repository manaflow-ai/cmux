import CmuxHomeRender
import CoreGraphics
import Foundation
import os

/// cmux: Mermaid diagrams in Home bubbles, as a drawn custom row
/// (CustomRows.swift, `Part.custom` of kind ``kind``).
///
/// `HomeMapping.parts` cuts an agent's or a person's text at its closed
/// ```` ```mermaid ```` fences (`HomeMermaidSplitter`); each fence whose
/// source the renderer draws becomes one bubble of this kind, and a source it
/// refuses stays in the text as written. The bubble's size is the renderer's
/// layout (plus ``padding``), known before any pixel is drawn, so the row
/// never moves when the image arrives; the row bitmap (off the main thread)
/// draws the image into it. Copy and VoiceOver read the Mermaid source.
///
/// The provider lives in the vendored custom-row registry, which is process
/// wide: ``install(_:)`` registers it once per renderer, and the mapping asks
/// the registry (``installed``), so every place that maps parts (the
/// projection, the diff's part owners, the draft) splits the same way.
final class HomeDiagramRowProvider: TranscriptCustomRowProvider {
    static let kind = "cmux.mermaid"
    /// Space between the bubble's edge and the diagram.
    static let padding: CGFloat = 10
    /// Taller diagrams scale down to this height (a long chain stays one screen).
    static let maxHeight: CGFloat = 560
    /// Sources longer than this stay text (Mermaid's own `maxTextSize`).
    static let maxSource = 50_000

    let renderer: any HomeDiagramRendering
    /// The layout width each measured bubble came from, by source and bubble size: `drawRow`
    /// gets only the bubble rect and must draw the render `measure` sized.
    // Lock carve-out: measure and drawRow are synchronous calls from the loader queue and the
    // row bitmap threads (CustomRows.swift); the map is a tiny critical section.
    private let widths = OSAllocatedUnfairLock<[WidthKey: CGFloat]>(initialState: [:])

    private struct WidthKey: Hashable {
        var source: String
        var width: Int
        var height: Int
    }

    private struct Payload: Codable {
        var source: String
    }

    init(renderer: any HomeDiagramRendering) {
        self.renderer = renderer
    }

    /// The registered provider (nil: Mermaid fences stay text).
    static var installed: HomeDiagramRowProvider? { CustomRows.provider(kind) as? HomeDiagramRowProvider }

    /// Registers `renderer` for Home's diagram bubbles (once per renderer: registering clears the
    /// registry's measure cache) and warms it off the main thread.
    static func install(_ renderer: any HomeDiagramRendering) {
        guard installed?.renderer !== renderer else { return }
        CustomRows.register(HomeDiagramRowProvider(renderer: renderer))
        Task.detached(priority: .utility) {
            _ = renderer.layout(mermaid: "graph TD\nA-->B", maxWidth: Fixture.maxTextWidth)
        }
    }

    /// The bubble for `source`, or nil when the renderer refuses it (it then stays text).
    func part(_ source: String) -> Part? {
        guard source.utf16.count <= Self.maxSource, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              renderer.layout(mermaid: source, maxWidth: Fixture.maxTextWidth) != nil,
              let custom = try? CustomPart(kind: Self.kind, version: Self.version(source), value: Payload(source: source))
        else { return nil }
        return .custom(custom)
    }

    /// The Mermaid source a diagram part carries.
    static func source(_ part: CustomPart) -> String? { part.decode(Payload.self)?.source }

    /// A stable version per source (FNV-1a): the registry's measure cache keys on it, so a
    /// streamed reply whose diagram changes is measured again.
    static func version(_ source: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in source.utf8 { hash = (hash ^ UInt32(truncatingIfNeeded: byte)) &* 16_777_619 }
        return Int(truncatingIfNeeded: hash & 0x7fff_ffff)
    }

    // MARK: TranscriptCustomRowProvider

    var kind: String { Self.kind }
    var measuresOffMain: Bool { true }
    var drawsRow: Bool { true }
    func layout(for part: CustomPart) -> CustomRowLayout { .sender }
    func makeView() -> CustomRowPlatformView { CustomRowPlatformView() }
    func configure(_ view: CustomRowPlatformView, part: CustomPart, context: CustomRowContext) {}
    func plainText(_ part: CustomPart) -> String? { Self.source(part) }

    func measure(_ part: CustomPart, maxWidth: CGFloat) -> CGSize {
        let pad = Self.padding
        let room = max(1, maxWidth - 2 * pad)
        guard let source = Self.source(part), let natural = renderer.layout(mermaid: source, maxWidth: room) else {
            return CGSize(width: min(maxWidth, 120), height: 2 * pad + 16)
        }
        let fitted = Self.fit(natural, width: room, height: Self.maxHeight)
        let size = CGSize(width: (fitted.width + 2 * pad).rounded(.up), height: (fitted.height + 2 * pad).rounded(.up))
        let key = WidthKey(source: source, width: CrashGuard.int(size.width), height: CrashGuard.int(size.height))
        widths.withLock { memo in
            if memo.count > 512 { memo.removeAll(keepingCapacity: true) }
            memo[key] = room
        }
        return size
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let source = Self.source(part) else { return }
        let content = rect.insetBy(dx: Self.padding, dy: Self.padding)
        guard content.width > 0, content.height > 0 else { return }
        let key = WidthKey(source: source, width: CrashGuard.int(rect.width.rounded()), height: CrashGuard.int(rect.height.rounded()))
        let room = widths.withLock { $0[key] } ?? content.width
        guard let natural = renderer.layout(mermaid: source, maxWidth: room), natural.width > 0, natural.height > 0 else { return }
        let target = Self.fit(natural, width: content.width, height: content.height)
        let frame = CGRect(x: content.midX - target.width / 2, y: content.midY - target.height / 2, width: target.width, height: target.height)
        let device = ctx.userSpaceToDeviceSpaceTransform
        let deviceScale = max(1, hypot(device.a, device.b))
        let scale = max(1, deviceScale * target.width / natural.width)
        guard let image = renderer.image(mermaid: source, maxWidth: room, style: Self.style(outgoing: context.outgoing), scale: scale)
        else { return }
        // The row context is y-down (RowDrawing's text matrix); a CGImage draws y-up.
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: frame.size))
        ctx.restoreGState()
    }

    /// `size` scaled down (never up) to fit `width` x `height`, keeping its aspect.
    static func fit(_ size: CGSize, width: CGFloat, height: CGFloat) -> CGSize {
        let factor = min(1, width / max(1, size.width), height / max(1, size.height))
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    /// The bubble's colours (Fixture: the theme, light or dark, key or not, elevated).
    static func style(outgoing: Bool) -> HomeDiagramStyle {
        HomeDiagramStyle(background: color(outgoing ? Fixture.outgoing : Fixture.incoming),
                         foreground: color(outgoing ? Fixture.outgoingText : Fixture.incomingText),
                         accent: color(outgoing ? Fixture.outgoingText : Fixture.incomingLink))
    }

    private static func color(_ c: UIColor) -> HomeColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return HomeColor(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: s.alphaComponent)
    }
}
