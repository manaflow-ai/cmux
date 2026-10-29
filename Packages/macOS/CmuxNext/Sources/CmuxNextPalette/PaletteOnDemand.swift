public import CmuxNextActions
public import CmuxNextWakeups

/// The App's command palette, built at its first use, as Chrome makes a keyed service
/// at its first `GetForProfile` (components/keyed_service/core/keyed_service_factory.cc) and posts the
/// rest of its launch work after startup (chrome/browser/after_startup_task_utils.cc).
///
/// Launch builds no ``PaletteController``: owners add their pages and providers to ``sources`` before it
/// exists, the palette's actions are bound to closures that build it when they run
/// (``bindRegistryActions()``), ``postBuild(on:)`` builds it right after the first frame, and a palette
/// key before that builds it in the key's turn.
///
/// ```swift
/// let palettes = PaletteOnDemand(registry: registry, sources: { PaletteSources() }) { sources in
///     PaletteController(registry: registry, sources: sources)
/// }
/// palettes.sources.actionPages["tab.search"] = page  // builds nothing
/// palettes.whenBuilt { $0.onPresented = report }
/// palettes.bindRegistryActions()
/// palettes.postBuild(on: startup)
/// ```
public final class PaletteOnDemand {
    /// The palette once built; nil until then.
    public private(set) var built: PaletteController?
    private let registry: ActionRegistry
    private let makeSources: () -> PaletteSources
    private let make: (PaletteSources) -> PaletteController
    /// The sources the palette is built with, made at their first read.
    private var staged: PaletteSources?
    private var builtHooks: [(PaletteController) -> Void] = []

    /// - Parameters:
    ///   - registry: The registry the palette's actions are bound on.
    ///   - sources: The palette's first sources, made at the first read of ``sources``.
    ///   - make: Builds the palette with the sources the owners added.
    public init(registry: ActionRegistry, sources: @escaping () -> PaletteSources,
                make: @escaping (PaletteSources) -> PaletteController) {
        self.registry = registry
        makeSources = sources
        self.make = make
    }

    /// The palette, built now if it is not yet: with ``sources``, then each ``whenBuilt(_:)`` hook in order.
    public var controller: PaletteController {
        if let built { return built }
        let palette = make(stagedSources)
        built = palette
        staged = nil
        let hooks = builtHooks
        builtHooks = []
        for hook in hooks { hook(palette) }
        return palette
    }

    /// The built palette's sources, or the ones it will be built with. Reading or writing builds nothing.
    public var sources: PaletteSources {
        get { built?.sources ?? stagedSources }
        set {
            if let built { built.sources = newValue } else { staged = newValue }
        }
    }

    /// Runs `body` with the palette once it is built, or now when it is.
    public func whenBuilt(_ body: @escaping (PaletteController) -> Void) {
        if let built { return body(built) }
        builtHooks.append(body)
    }

    /// Binds the palette's own actions and the registry's argument collector to ``controller``: a run
    /// before the palette is built builds it in that run's turn.
    public func bindRegistryActions() {
        PaletteController.bindRegistryActions(on: registry, goToWorkspace: sources.workspaces != nil) { [weak self] in
            self?.controller
        }
    }

    /// Builds the palette right after the first frame (`Palette.build`, main, at the visible class behind input).
    public func postBuild(on startup: StartupScheduler) {
        startup.post(.afterFirstFrame, "Palette.build", on: .main) { [weak self] in _ = self?.controller }
    }

    private var stagedSources: PaletteSources {
        if let staged { return staged }
        let sources = makeSources()
        staged = sources
        return sources
    }
}
