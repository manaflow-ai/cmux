public import CmuxHomeRender
public import CoreGraphics
public import Foundation
import JavaScriptCore
import os

/// Home chat's Mermaid renderer: Ondine (the bundled `ondine.min.js`, a Rust
/// Mermaid compiler in WebAssembly) in one JavaScriptCore context, its SVG
/// recoloured for the bubble and drawn by CoreSVG.
///
/// The context loads on first use (or ``prewarm()``); a render after that
/// takes well under a millisecond. Renders and images are cached by source,
/// width, colours and scale, so a row measured and redrawn many times renders
/// once.
///
/// ```swift
/// let renderer = OndineMermaidRenderer(script: resources.appending(path: "markdown-viewer/ondine.min.js"))
/// let size = renderer.layout(mermaid: "graph TD\nA-->B", maxWidth: 340)
/// ```
public nonisolated final class OndineMermaidRenderer: HomeDiagramRendering, Sendable {
    // Checked Sendable: every stored value is an immutable Sendable let; the mutable ones (the
    // context, the caches) live in `state` and are read and written only inside its lock.
    /// Ondine's text size in points (the transcript's body text is 13 pt; diagrams are denser).
    public static let fontSize: CGFloat = 12
    /// Sources longer than this are refused (Mermaid's own `maxTextSize`).
    public static let maxSource = 50_000

    private let script: URL
    private let resolver = SVGCustomPropertyResolver()
    private let flattener = SVGTextFlattener()
    private let rasterizer = SVGRasterizer()
    // Lock carve-out: the transcript's custom rows call `layout` and `image` synchronously from the
    // page loader's queue and the row bitmap threads, so an actor cannot serve them. JavaScriptCore
    // runs one call at a time per context anyway; the lock also guards the caches.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    nonisolated private struct State {
        var context: JSContext?
        var render: JSValue?
        var loadFailed = false
        var renders: [RenderKey: Rendered?] = [:]
        var images: [ImageKey: CGImage] = [:]
    }

    nonisolated private struct RenderKey: Hashable {
        var source: String
        var maxWidth: CGFloat
    }

    nonisolated private struct ImageKey: Hashable {
        var render: RenderKey
        var style: HomeDiagramStyle
        var scale: CGFloat
    }

    nonisolated private struct Rendered {
        var svg: String
        var size: CGSize
    }

    /// - Parameter script: the Ondine script (`ondine.min.js`, which sets `globalThis.ondine`).
    public init(script: URL) {
        self.script = script
    }

    /// The renderer over the app bundle's `markdown-viewer/ondine.min.js`, or nil when the bundle has none.
    public static func bundled(appResources: URL? = Bundle.main.resourceURL) -> OndineMermaidRenderer? {
        guard let script = appResources?.appending(path: "markdown-viewer/ondine.min.js"),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return OndineMermaidRenderer(script: script)
    }

    /// Loads the script and compiles Ondine's WebAssembly now, so the first diagram does not wait for it.
    public func prewarm() {
        _ = layout(mermaid: "graph TD\nA-->B", maxWidth: 300)
    }

    public func layout(mermaid source: String, maxWidth: CGFloat) -> CGSize? {
        rendered(source, maxWidth: maxWidth)?.size
    }

    public func image(mermaid source: String, maxWidth: CGFloat, style: HomeDiagramStyle, scale: CGFloat) -> CGImage? {
        guard let rendered = rendered(source, maxWidth: maxWidth) else { return nil }
        let key = ImageKey(render: RenderKey(source: source, maxWidth: maxWidth), style: style, scale: scale)
        if let hit = state.withLockUnchecked({ $0.images[key] }) { return hit }
        let svg = recoloured(rendered.svg, style: style)
        guard let image = rasterizer.image(svg: svg, size: rendered.size, scale: scale) else { return nil }
        state.withLockUnchecked { state in
            if state.images.count >= 64 { state.images.removeAll(keepingCapacity: true) }
            state.images[key] = image
        }
        return image
    }

    /// Ondine's own SVG for `source` (custom properties unresolved), for tests and debugging.
    func debugSVG(mermaid source: String, maxWidth: CGFloat) -> String? {
        rendered(source, maxWidth: maxWidth)?.svg
    }

    /// Ondine's SVG with concrete colours for `style` and one `<text>` per line: what CoreSVG draws.
    func recoloured(_ svg: String, style: HomeDiagramStyle) -> String {
        flattener.flatten(resolver.resolve(svg, overrides: OndineDiagramColors(style: style).overrides))
    }

    /// Ondine's SVG and size for `source` at `maxWidth` (cached, failures too).
    private func rendered(_ source: String, maxWidth: CGFloat) -> Rendered? {
        guard !source.isEmpty, source.utf16.count <= Self.maxSource, maxWidth > 0 else { return nil }
        let key = RenderKey(source: source, maxWidth: maxWidth)
        return state.withLockUnchecked { state in
            if let hit = state.renders[key] { return hit }
            let result = Self.run(&state, script: script, source: source, maxWidth: maxWidth)
            if state.renders.count >= 256 { state.renders.removeAll(keepingCapacity: true) }
            state.renders[key] = .some(result)
            return result
        }
    }

    /// One Ondine render inside the lock; loads the context first.
    private static func run(_ state: inout State, script: URL, source: String, maxWidth: CGFloat) -> Rendered? {
        if state.render == nil, !state.loadFailed {
            state.render = load(script)
            state.context = state.render?.context
            state.loadFailed = state.render == nil
        }
        guard let render = state.render,
              let result = render.call(withArguments: [source, Double(maxWidth), Double(fontSize)]),
              result.isObject, let svg = result.forProperty("svg")?.toString(), svg.hasPrefix("<svg"),
              let width = result.forProperty("width")?.toDouble(), let height = result.forProperty("height")?.toDouble(),
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return nil }
        return Rendered(svg: svg, size: CGSize(width: width, height: height))
    }

    /// A context with the shims, Ondine and the render function; nil when the script fails.
    private static func load(_ script: URL) -> JSValue? {
        guard let code = try? String(contentsOf: script, encoding: .utf8), let context = JSContext() else { return nil }
        context.evaluateScript(ondineHostShims)
        context.evaluateScript(code, withSourceURL: script)
        let render = context.evaluateScript("""
            (function () {
              var renderer = ondine.create({ modules: { all: ondine.wasm } });
              return function (source, maxWidth, fontSize) {
                try {
                  var r = renderer.render(source, { maxWidth: maxWidth, fontSize: fontSize, idPrefix: "cmux-home-" });
                  return { svg: r.svg, width: r.width, height: r.height };
                } catch (e) {
                  return null;
                }
              };
            })()
            """)
        // An uncaught exception stays in `exception`: the script or the shims did not load.
        guard context.exception == nil, let render, render.isObject else { return nil }
        return render
    }
}
