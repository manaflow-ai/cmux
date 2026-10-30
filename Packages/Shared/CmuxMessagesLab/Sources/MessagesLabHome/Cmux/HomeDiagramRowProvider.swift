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
    /// Bumped on the main actor when the engine loaded for fences that mapped as text meanwhile:
    /// the transcripts showing them map again (`HomeProjection.observeDiagrams`).
    let readiness = HomeDiagramReadiness()
    // Lock carve-out: measure and drawRow are synchronous calls from the loader queue and the
    // row bitmap threads (CustomRows.swift), and the mapping that warms the engine runs on any
    // thread; each section is a few field reads and writes.
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        /// The layout width each measured bubble came from, by source and bubble size: `drawRow`
        /// gets only the bubble rect and must draw the render `measure` sized.
        var widths: [WidthKey: CGFloat] = [:]
        /// A ``HomeDiagramRowProvider/warm()`` task is loading the engine.
        var warming = false
        /// A closed fence mapped as text because the engine was not loaded.
        var deferred = false
    }

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
    /// registry's measure cache). A renderer that keeps its engine for its life loads it now, off the
    /// main thread; the others load it for the first Mermaid fence (``warm()``), so a Home with no
    /// diagram never holds it.
    static func install(_ renderer: any HomeDiagramRendering) {
        guard installed?.renderer !== renderer else { return }
        let provider = HomeDiagramRowProvider(renderer: renderer)
        CustomRows.register(provider)
        if renderer.prewarmsAtInstall { provider.warm() }
    }

    /// Loads the renderer's engine off the main thread, for a Mermaid fence open or closed while it is
    /// cold; the fences that mapped as text meanwhile map again once it is loaded (``readiness``), as
    /// Blink lays text out in a fallback font and again when the web font loads (font-display swap,
    /// third_party/blink/renderer/core/css/font_face.cc). Nothing loads while memory is critical.
    func warm() {
        let cold = renderer.needsPrewarm, ready = renderer.isReady
        let start = state.withLock { state -> Bool in
            guard !state.warming, cold || (state.deferred && ready) else { return false }
            state.warming = true
            return true
        }
        guard start else { return }
        let renderer = renderer
        Task(priority: .utility) {
            await Self.prewarm(renderer)
            await self.warmed()
        }
    }

    @concurrent private static func prewarm(_ renderer: any HomeDiagramRendering) async {
        renderer.prewarm()
    }

    /// The warm finished: fences that mapped as text map again when the engine is loaded now.
    private func warmed() async {
        let ready = renderer.isReady
        let remap = state.withLock { state -> Bool in
            state.warming = false
            guard state.deferred, ready else { return false }
            state.deferred = false
            return true
        }
        if remap { await readiness.engineLoaded() }
    }

    /// The bubble for `source`, or nil when the renderer refuses it (it then stays text). While the
    /// engine is not loaded the fence stays text, the engine loads off the main thread (``warm()``)
    /// and the fence maps again then: a layout here would load it on the mapping's thread.
    func part(_ source: String) -> Part? {
        guard source.utf16.count <= Self.maxSource, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard renderer.isReady else {
            state.withLock { $0.deferred = true }
            warm()
            return nil
        }
        // Fences deferred while a critical limit kept the engine from warming map again now that a row loaded it.
        warm()
        guard renderer.layout(mermaid: source, maxWidth: Fixture.maxTextWidth) != nil,
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
        state.withLock { state in
            if state.widths.count > 512 { state.widths.removeAll(keepingCapacity: true) }
            state.widths.updateValue(room, forKey: key)
        }
        return size
    }

    func drawRow(_ part: CustomPart, in ctx: CGContext, rect: CGRect, context: CustomRowDrawContext) {
        guard let source = Self.source(part) else { return }
        let content = rect.insetBy(dx: Self.padding, dy: Self.padding)
        guard content.width > 0, content.height > 0 else { return }
        let key = WidthKey(source: source, width: CrashGuard.int(rect.width.rounded()), height: CrashGuard.int(rect.height.rounded()))
        let room = state.withLock { $0.widths[key] } ?? content.width
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
