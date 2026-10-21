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
}
