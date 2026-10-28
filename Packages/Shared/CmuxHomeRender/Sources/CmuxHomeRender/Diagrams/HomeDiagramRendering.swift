public import CoreGraphics

/// Draws Mermaid source as a diagram for the Home transcript.
///
/// The transcript lays a row out before it draws it, and a row never moves
/// afterwards, so a diagram's size comes first (``layout(mermaid:maxWidth:)``)
/// and its pixels later (``image(mermaid:maxWidth:style:scale:)``), from the
/// same render. A source the renderer refuses (`nil` from `layout`) stays as
/// its fenced source text.
///
/// Both calls are synchronous and may run on any thread: rows are measured on
/// the page loader's queue and their bitmaps are drawn off the main actor.
/// Conformers keep both calls deterministic for the same arguments and cache
/// their work, because a row is measured and drawn many times.
///
/// The render core itself has no diagram engine. The Mac app passes its
/// JavaScriptCore renderer; a host without one passes none and Mermaid fences
/// stay text.
///
/// ```swift
/// final class FixedDiagrams: HomeDiagramRendering {
///     func layout(mermaid source: String, maxWidth: CGFloat) -> CGSize? {
///         CGSize(width: min(120, maxWidth), height: 80)
///     }
///     func image(mermaid source: String, maxWidth: CGFloat, style: HomeDiagramStyle, scale: CGFloat) -> CGImage? { nil }
/// }
/// ```
public protocol HomeDiagramRendering: AnyObject, Sendable {
    /// The diagram's size in points when it is laid out at most `maxWidth` wide.
    ///
    /// - Parameters:
    ///   - source: the Mermaid source between the fences, without the fence lines.
    ///   - maxWidth: the widest the diagram may be, in points.
    /// - Returns: the size, or `nil` when the source does not render (the
    ///   transcript then shows the source as text).
    func layout(mermaid source: String, maxWidth: CGFloat) -> CGSize?

    /// The pixels of the diagram that ``layout(mermaid:maxWidth:)`` measured for
    /// the same `source` and `maxWidth`.
    ///
    /// - Parameters:
    ///   - source: the Mermaid source, as given to `layout`.
    ///   - maxWidth: the width given to `layout`.
    ///   - style: the colours of the bubble the diagram sits in.
    ///   - scale: device pixels per point; the image is the laid-out size times this.
    /// - Returns: the image, or `nil` when the source does not render.
    func image(mermaid source: String, maxWidth: CGFloat, style: HomeDiagramStyle, scale: CGFloat) -> CGImage?

    /// Whether `layout` and `image` answer now without loading an engine first (the engine is
    /// loaded, or failed to load). Never waits: the main thread asks it before every diagram it
    /// maps, and maps the fence as text while it is false.
    var isReady: Bool { get }

    /// Whether the engine is not loaded and may load now (memory is not critical). The transcript
    /// asks for an opening Mermaid fence and for a closed one while ``isReady`` is false. Never waits.
    var needsPrewarm: Bool { get }

    /// Whether the transcript loads the engine as soon as the renderer is installed, before any
    /// fence: a renderer that keeps its engine for its life.
    var prewarmsAtInstall: Bool { get }

    /// Loads the renderer's engine now, so the next diagram does not wait for it. Synchronous and
    /// slow: call it off the main thread. Does nothing when it is loaded, loading, or may not load.
    func prewarm()
}

extension HomeDiagramRendering {
    /// A renderer with no engine to load is always ready.
    public var isReady: Bool { true }

    /// A renderer with no engine to load never needs a prewarm.
    public var needsPrewarm: Bool { false }

    public var prewarmsAtInstall: Bool { false }

    public func prewarm() {}
}
