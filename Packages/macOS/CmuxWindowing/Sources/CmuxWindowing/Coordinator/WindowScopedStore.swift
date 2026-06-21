/// A per-window model store keyed by ``WindowID``.
///
/// This is the canonical shape every domain uses to de-aggregate per-window
/// state (owner ruling 2026-06-18: per-window state is domain-owned and
/// `WindowID`-keyed, never bundled into one per-window aggregate such as the
/// rejected `AppDelegate.MainWindowContext`). A domain owns one
/// `WindowScopedStore<ItsModel>`, stores a model under each live ``WindowID``,
/// reads it back by ``WindowID`` when a window-scoped command needs it, and
/// drops a window's slice via ``remove(_:)`` when that window tears down.
///
/// `Value` is generic so the package never names an app-target model type: the
/// app constructs `WindowScopedStore<CmuxConfigStore>` (and, as more domains
/// peel out of the aggregate, `WindowScopedStore<SidebarState>` and the rest)
/// at the composition root.
///
/// ## Teardown is owner-driven, not stream-driven
///
/// The store does NOT subscribe to ``WindowManaging/windowClosed`` itself. That
/// stream is a single-consumer `AsyncStream` (one continuation, each element
/// delivered to exactly one awaiting iterator), and its sole consumer is the
/// app target's window-teardown loop, which already removes each closing
/// window's slice on every teardown path (the AppKit close path and the
/// explicit/windowless teardown path both call ``remove(_:)``). A second
/// `for await` here would split close events with that teardown loop and
/// silently starve it, so the store stays a passive dictionary and the single
/// owner of the close stream drives both teardown and slice removal in one
/// place. A future broadcast/fan-out of `windowClosed` (so N independent
/// domains can each subscribe) is a separate change that must add multicast to
/// the conformer first; until then, removal is explicit.
///
/// ## Isolation
///
/// `@MainActor` because its mutators run on the main thread alongside window
/// registration and AppKit teardown, co-locating the state with its callers so
/// no cross-actor bridge is needed (mirrors ``WindowCoordinator``'s isolation
/// ruling).
@MainActor
public final class WindowScopedStore<Value> {
    /// The per-window models, keyed by ``WindowID``.
    private var entries: [WindowID: Value] = [:]

    /// Creates an empty store. The app target holds one per domain at the
    /// composition root and drops slices via ``remove(_:)`` as windows close.
    public init() {}

    /// The model stored for `id`, or `nil` if no window has one.
    public func model(for id: WindowID) -> Value? {
        entries[id]
    }

    /// Stores `model` for `id`, replacing any prior model for that window.
    public func setModel(_ model: Value, for id: WindowID) {
        entries[id] = model
    }

    /// Removes and returns the model stored for `id`, if any. Called by the
    /// owning teardown path when a window closes; idempotent if already gone.
    @discardableResult
    public func remove(_ id: WindowID) -> Value? {
        entries.removeValue(forKey: id)
    }

    /// Every stored model, in no guaranteed order. Mirrors the legacy
    /// aggregate-wide sweeps (e.g. reloading every window's config store).
    public var models: [Value] {
        Array(entries.values)
    }

    /// The ``WindowID`` of every window that currently has a model, in no
    /// guaranteed order. Lets a sweep that needs the window identity (not just
    /// the model) enumerate the live windows this domain knows about.
    public var ids: [WindowID] {
        Array(entries.keys)
    }

    /// Every `(WindowID, Value)` pair, in no guaranteed order. Mirrors the
    /// legacy aggregate's `values` iteration for callers that resolve a
    /// per-window value alongside its identity in one pass.
    public var pairs: [(id: WindowID, model: Value)] {
        entries.map { (id: $0.key, model: $0.value) }
    }
}
