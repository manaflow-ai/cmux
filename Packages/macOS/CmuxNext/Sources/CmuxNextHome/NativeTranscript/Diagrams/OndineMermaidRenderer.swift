public import CmuxHomeRender
public import CmuxNextCompat
import CmuxNextWakeups
public import CoreGraphics
public import Foundation
import JavaScriptCore

/// Home chat's Mermaid renderer: Ondine (the bundled `ondine.min.js`, a Rust
/// Mermaid compiler in WebAssembly) in one JavaScriptCore context, its SVG
/// recoloured for the bubble and drawn by CoreSVG.
///
/// The context loads for the first diagram (``prewarm()`` or the first layout); a render after that
/// takes well under a millisecond. ``isReady`` says, without waiting, whether a layout would load it
/// first; the transcript then maps the fence as text and loads it off the main thread. Renders and
/// images are cached by source, width, colours and scale, so a row measured and redrawn many times
/// renders once. Both caches are least recently used: renders up to ``renderEntries``, images up to
/// ``imageBytes`` of pixels.
///
/// The renderer is a lossless memory consumer (``registerMemoryConsumer(with:hop:)``, Chrome's
/// `base/memory_coordinator/memory_consumer.h`): a lower limit trims the images, the critical limit
/// also drops the renders and the context, and with `idleRelease` the context goes once no diagram
/// was shown for that long (as Chrome stops an idle service worker and starts it again on the next
/// event, `kIdleWorkerTimeout` in content/browser/service_worker/service_worker_version.cc). Entries
/// used in the last 2 s (``MemoryLimit/workingSet``) stay at every limit. The next layout loads the
/// context again and gives the same size.
///
/// ```swift
/// let renderer = OndineMermaidRenderer(script: resources.appending(path: "markdown-viewer/ondine.min.js"))
/// let size = renderer.layout(mermaid: "graph TD\nA-->B", maxWidth: 340)
/// ```
public nonisolated final class OndineMermaidRenderer: HomeDiagramRendering, AsyncMemoryConsumer, Sendable {
    // Checked Sendable: every stored value is an immutable Sendable let; the mutable ones (the
    // context, the caches) live in `state` and are read and written only inside its lock.
    /// Ondine's text size in points (the transcript's body text is 13 pt; diagrams are denser).
    public static let fontSize: CGFloat = 12
    /// Sources longer than this are refused (Mermaid's own `maxTextSize`).
    public static let maxSource = 50_000
    /// The renders kept at the full limit (a source's SVG and size, failures too).
    public static let renderEntries = 256
    /// The image pixel bytes kept at the full limit: about a dozen full-width diagrams at 2x.
    public static let imageBytes = 32 << 20
    /// How long the context stays with no diagram shown, when the app releases it when idle.
    public static let idleRelease: Duration = .seconds(600)
    /// What the renderer holds and what freeing it costs: decoded images and SVG text, rebuilt by a
    /// raster or a render; only memory is touched.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// True for a renderer that keeps its context for its life (no memory coordinator).
    public let prewarmsAtInstall: Bool
    private let script: URL
    private let resolver = SVGCustomPropertyResolver()
    private let flattener = SVGTextFlattener()
    private let rasterizer = SVGRasterizer()
    private let imageCap: Int
    /// Time since the renderer was made, on the injected clock: entry use times and the idle deadline.
    private let elapsed: @Sendable () -> Duration
    /// The one-shot idle deadline (nil: the context stays for the renderer's life).
    private let idle: DemandTimer?
    private let idleAfter: Duration
    private let contextReleased: @Sendable () -> Void
    private let memorySlot = AsyncMemoryConsumerSlot()
    /// The context is loaded or failed to load (``isReady``); written inside the lock with each change.
    private let answers = Atomic<Bool>(false)
    /// The limit is critical (no ``prewarm()``); written inside the lock with each limit.
    private let critical = Atomic<Bool>(false)
    // Lock carve-out: the transcript's custom rows call `layout` and `image` synchronously from the
    // page loader's queue and the row bitmap threads, so an actor cannot serve them. JavaScriptCore
    // runs one call at a time per context anyway; the lock also guards the caches. The script file
    // is read with the lock free (`rendered`).
    private let state: Mutex<State>

    nonisolated private struct State {
        var context: JSContext?
        var render: JSValue?
        var loadFailed = false
        /// A ``OndineMermaidRenderer/prewarm()`` is reading the script.
        var warming = false
        var renders = RecentEntries<RenderKey, Rendered?>()
        var images = RecentEntries<ImageKey, CGImage>()
        var limit = MemoryLimit.default
        /// When a diagram was last drawn (or the context loaded), on ``OndineMermaidRenderer/elapsed``.
        var lastShown: Duration = .zero

        /// A layout runs without loading the context first: it is loaded or failed to load.
        var answers: Bool { render != nil || loadFailed }
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

    /// - Parameters:
    ///   - script: the Ondine script (`ondine.min.js`, which sets `globalThis.ondine`).
    ///   - imageBytes: the image pixel bytes kept at the full limit.
    ///   - idleRelease: drops the context once no diagram was shown for this long; nil keeps it.
    ///   - clock: the clock of use times and the idle deadline (tests pass a manual one).
    ///   - prewarmsAtInstall: the transcript loads the context when it installs the renderer.
    public convenience init(script: URL, imageBytes: Int = OndineMermaidRenderer.imageBytes, idleRelease: Duration? = nil,
                            clock: any Clock<Duration> = ContinuousClock(), prewarmsAtInstall: Bool = false) {
        self.init(script: script, imageBytes: imageBytes, idleRelease: idleRelease, clock: clock,
                  prewarmsAtInstall: prewarmsAtInstall, contextReleased: {})
    }

    /// The designated init; `contextReleased` runs after an idle deadline dropped the context (tests wait on it).
    init(script: URL, imageBytes: Int, idleRelease: Duration?, clock: any Clock<Duration>, prewarmsAtInstall: Bool = false,
         contextReleased: @escaping @Sendable () -> Void) {
        self.script = script
        self.prewarmsAtInstall = prewarmsAtInstall
        imageCap = max(imageBytes, 0)
        elapsed = Self.stopwatch(clock)
        idle = idleRelease.map { _ in DemandTimer(owner: "OndineMermaidRenderer.idle", clock: clock) }
        idleAfter = idleRelease ?? .zero
        self.contextReleased = contextReleased
        state = Mutex(State())
    }

    deinit {
        idle?.cancel()
    }

    /// The renderer over the app bundle's `markdown-viewer/ondine.min.js`, or nil when the bundle has
    /// none. It keeps the context for its life, loaded when the transcript installs it.
    ///
    /// - Parameter appResources: the app bundle's resources folder.
    public static func bundled(appResources: URL? = Bundle.main.resourceURL) -> OndineMermaidRenderer? {
        bundledScript(appResources).map { OndineMermaidRenderer(script: $0, prewarmsAtInstall: true) }
    }

    /// The app's one renderer over the bundle's script: with `memory` it is the coordinator's
    /// `home-diagrams` consumer, loads its context for the first Mermaid fence and drops it after
    /// ``idleRelease`` with no diagram shown; without it, it is ``bundled(appResources:)``.
    ///
    /// - Parameters:
    ///   - memory: the app's memory coordinator, or nil while the feature that registers it is off.
    ///   - appResources: the app bundle's resources folder.
    @MainActor public static func bundled(memory: (any MemoryConsumerRegistry)?,
                                          appResources: URL? = Bundle.main.resourceURL) -> OndineMermaidRenderer? {
        guard let script = bundledScript(appResources) else { return nil }
        guard let memory else { return OndineMermaidRenderer(script: script, prewarmsAtInstall: true) }
        let renderer = OndineMermaidRenderer(script: script, idleRelease: idleRelease)
        renderer.registerMemoryConsumer(with: memory)
        return renderer
    }

    /// The bundle's `markdown-viewer/ondine.min.js`, or nil when it has none.
    private static func bundledScript(_ appResources: URL?) -> URL? {
        guard let script = appResources?.appending(path: "markdown-viewer/ondine.min.js"),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return script
    }

    public func layout(mermaid source: String, maxWidth: CGFloat) -> CGSize? {
        rendered(source, maxWidth: maxWidth)?.size
    }

    public func image(mermaid source: String, maxWidth: CGFloat, style: HomeDiagramStyle, scale: CGFloat) -> CGImage? {
        guard let rendered = rendered(source, maxWidth: maxWidth) else { return nil }
        let key = ImageKey(render: RenderKey(source: source, maxWidth: maxWidth), style: style, scale: scale)
        let now = elapsed()
        let hit = state.withLock { state in
            state.lastShown = now
            return state.images.value(for: key, at: now)
        }
        if let hit { return hit }
        let svg = recoloured(rendered.svg, style: style)
        guard let image = rasterizer.image(svg: svg, size: rendered.size, scale: scale) else { return nil }
        let imageCap = imageCap
        state.withLock { state in
            state.images.set(image, cost: image.bytesPerRow * image.height, for: key, at: now)
            state.images.trim(toCost: state.limit.scale(imageCap), keepingUsedAfter: now - MemoryLimit.workingSet)
            state.images.trim(toCost: imageCap, keepingUsedAfter: nil)
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

    /// Whether the JavaScriptCore context is loaded now (tests).
    var hasContext: Bool { state.withLock { $0.render != nil } }

    /// The image cache's pixel bytes and the render cache's entries now (tests).
    var cacheSizes: (imageBytes: Int, renders: Int) { state.withLock { ($0.images.cost, $0.renders.count) } }

    /// Never waits: one atomic load, no lock (a load holds the lock while it runs the script).
    public var isReady: Bool { answers.load(ordering: .acquiring) }

    /// Never waits, as ``isReady``. False at a critical limit: the context then loads again only for
    /// a diagram that a row measures or draws.
    public var needsPrewarm: Bool { !answers.load(ordering: .acquiring) && !critical.load(ordering: .acquiring) }

    /// Loads the script and compiles Ondine's WebAssembly now, so the first diagram does not wait for
    /// it. Does nothing when the context is loaded, failed to load, another prewarm reads the script,
    /// or the limit is critical.
    public func prewarm() {
        let cold = state.withLock { state -> Bool in
            guard state.render == nil, !state.loadFailed, !state.warming, !state.limit.isCritical else { return false }
            state.warming = true
            return true
        }
        guard cold else { return }
        let code = readScript()
        let now = elapsed()
        let loaded = state.withLock { state -> Bool in
            state.warming = false
            let didLoad = Self.loadContext(&state, script: script, code: code, at: now)
            publish(state.answers, critical: state.limit.isCritical)
            return didLoad
        }
        if loaded { armIdleRelease(after: idleAfter) }
    }

    /// Mirrors what ``isReady`` and ``needsPrewarm`` read; called inside the lock after each change.
    private func publish(_ answers: Bool, critical: Bool) {
        self.answers.store(answers, ordering: .releasing)
        self.critical.store(critical, ordering: .releasing)
    }

    /// What one pass of ``rendered(_:maxWidth:)`` under the lock found.
    private enum RenderPass {
        /// The render (nil: Ondine refused the source), and whether this pass loaded the context.
        case done(Rendered?, loadedContext: Bool)
        /// The context must load first and the script is not read yet.
        case needsScript
    }

    /// Ondine's SVG and size for `source` at `maxWidth` (cached, failures too).
    private func rendered(_ source: String, maxWidth: CGFloat) -> Rendered? {
        guard !source.isEmpty, source.utf16.count <= Self.maxSource, maxWidth > 0 else { return nil }
        let key = RenderKey(source: source, maxWidth: maxWidth)
        let now = elapsed()
        var outcome = state.withLock { state in Self.pass(&state, key: key, script: script, code: nil, at: now) }
        if case .needsScript = outcome {
            // The script is read only when the context must load, and with the lock free; a pass with it never asks again.
            let code = readScript()
            outcome = state.withLock { state in
                let found = Self.pass(&state, key: key, script: script, code: code, at: now)
                publish(state.answers, critical: state.limit.isCritical)
                return found
            }
        }
        guard case .done(let result, let loadedContext) = outcome else { return nil }
        if loadedContext { armIdleRelease(after: idleAfter) }
        return result
    }

    /// One render pass inside the lock: the cached render, else the context (loaded first from
    /// `code`) renders `key` and the result is cached; ``RenderPass/needsScript`` when the context
    /// must load and `code` is nil.
    private static func pass(_ state: inout State, key: RenderKey, script: URL, code: Result<String, any Error>?,
                             at now: Duration) -> RenderPass {
        if let hit = state.renders.value(for: key, at: now) { return .done(hit, loadedContext: false) }
        var loadedContext = false
        if state.render == nil, !state.loadFailed {
            guard let code else { return .needsScript }
            loadedContext = loadContext(&state, script: script, code: code, at: now)
        }
        let result = run(state.render, source: key.source, maxWidth: key.maxWidth)
        state.renders.set(result, cost: result?.svg.utf8.count ?? 0, for: key, at: now)
        if state.limit.isCritical { state.renders.trim(toCount: 0, keepingUsedAfter: now - MemoryLimit.workingSet) }
        state.renders.trim(toCount: renderEntries, keepingUsedAfter: nil)
        return .done(result, loadedContext: loadedContext)
    }

    /// The script's text; a blocking file read, so never called with the lock held.
    private func readScript() -> Result<String, any Error> {
        Result { try String(blockingContentsOf: script, encoding: .utf8) }
    }

    /// Loads the context from `code` (the text of `script`) when it is not loaded and has not failed to.
    ///
    /// - Returns: Whether this call loaded it.
    private static func loadContext(_ state: inout State, script: URL, code: Result<String, any Error>, at now: Duration) -> Bool {
        guard state.render == nil, !state.loadFailed else { return false }
        state.render = (try? code.get()).flatMap { load($0, from: script) }
        state.context = state.render?.context
        state.loadFailed = state.render == nil
        guard state.render != nil else { return false }
        state.lastShown = now
        return true
    }

    /// One Ondine render with `render`, the loaded render function; nil when there is none or Ondine refuses the source.
    private static func run(_ render: JSValue?, source: String, maxWidth: CGFloat) -> Rendered? {
        guard let render,
              let result = render.call(withArguments: [source, Double(maxWidth), Double(fontSize)]),
              result.isObject, let svg = result.forProperty("svg")?.toString(), svg.hasPrefix("<svg"),
              let width = result.forProperty("width")?.toDouble(), let height = result.forProperty("height")?.toDouble(),
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return nil }
        return Rendered(svg: svg, size: CGSize(width: width, height: height))
    }

    // MARK: Idle release

    /// Arms the one idle deadline `delay` from now unless one is pending (a pending one checks the
    /// last show when it fires and moves itself).
    private func armIdleRelease(after delay: Duration) {
        idle?.scheduleIfIdle(after: delay) { [weak self] in self?.idleDeadlineFired() }
    }

    /// Drops the context when no diagram was shown for ``idleAfter``; else waits for the rest of it.
    /// A context critical pressure dropped already leaves nothing to do.
    private func idleDeadlineFired() {
        let now = elapsed()
        let idleAfter = idleAfter
        let (dropped, remaining) = state.withLock { state -> (Bool, Duration?) in
            guard state.render != nil else { return (false, nil) }
            let idleFor = now - state.lastShown
            guard idleFor >= idleAfter else { return (false, idleAfter - idleFor) }
            Self.dropContext(&state)
            publish(state.answers, critical: state.limit.isCritical)
            return (true, nil)
        }
        if let remaining { armIdleRelease(after: remaining) }
        if dropped { contextReleased() }
    }

    /// Unlinks the context; the next render that needs it loads it again.
    private static func dropContext(_ state: inout State) {
        state.render = nil
        state.context = nil
    }

    /// Time on `clock` since this call.
    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    // MARK: Memory consumer

    public func updateMemoryLimit(_ limit: MemoryLimit) -> MemoryUsage? {
        state.withLock { state in
            state.limit = limit
            publish(state.answers, critical: state.limit.isCritical)
            return Self.usage(of: state)
        }
    }

    public func releaseMemory(downTo limit: MemoryLimit) -> MemoryUsage? {
        let cutoff = elapsed() - MemoryLimit.workingSet
        let imageCap = imageCap
        return state.withLock { state in
            state.images.trim(toCost: limit.scale(imageCap), keepingUsedAfter: cutoff)
            if limit.isCritical {
                state.renders.trim(toCount: 0, keepingUsedAfter: cutoff)
                Self.dropContext(&state)
                publish(state.answers, critical: state.limit.isCritical)
            }
            return Self.usage(of: state)
        }
    }

    /// The images' pixel bytes and the renders' SVG bytes, from the counters the caches keep.
    private static func usage(of state: State) -> MemoryUsage {
        MemoryUsage(footprintBytes: state.images.cost + state.renders.cost, entries: state.images.count + state.renders.count)
    }

    /// Registers the renderer with the app's memory coordinator (`home-diagrams`); the renderer keeps
    /// the registration, so the coordinator calls it while it lives.
    ///
    /// - Parameters:
    ///   - registry: The memory coordinator.
    ///   - hop: How the coordinator's calls leave the main actor (tests pass their own).
    @MainActor public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry, hop: AsyncMemoryConsumerHop = .task) {
        memorySlot.register(name: "home-diagrams", traits: Self.memoryTraits, consumer: self, registry: registry, hop: hop)
    }
}
