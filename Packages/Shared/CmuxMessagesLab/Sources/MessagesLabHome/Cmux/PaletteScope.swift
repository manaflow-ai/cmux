import AppKit
import os

/// cmux: one window view's palette (its Home chat's theme and Chat Colors…), with a stable id that keys every
/// palette-dependent cache. Equal themes share one box (``PaletteScope/box(for:)``), so equal palettes share
/// their row bitmaps and tiles, and two chats with different colours never read each other's.
// Not checked Sendable: FixtureTheme.swift:28 (`outgoingGradient: CGGradient?`) holds a CGGradient, which the SDK
// does not mark Sendable (fleet probe e72b1f95374d27da0c9f8e94, 2026-10-30). FixtureTheme is a struct of `let`s that
// nothing mutates after init. Owner: cmux-next Performance Lead (PR #28036); this waiver expires 2026-11-13.
// crash-allow: immutable: two `let`s set in init, before the box is published to any other thread, so any thread may read it.
final class PaletteBox: @unchecked Sendable {
    let theme: FixtureTheme
    let id: Int

    fileprivate init(_ theme: FixtureTheme, id: Int) {
        self.theme = theme
        self.id = id
    }
}

/// cmux: the palette of the window view whose work runs now on this thread, as `RenderScaleScope` is its scale.
/// Two Home chats can show at once with different bubble colours (Chat Colors…), so the palette is the view's own,
/// not one process value. Inside a scope `Fixture.theme` and `Fixture.paletteGeneration` are the view's; outside
/// one they are the process palette's: the chat the person last typed or clicked in (``claimProcess(_:)``), which
/// the composer, the send's flying bubble and the field read from AppKit callbacks. Work sent to another queue
/// takes the box with it (a task local does not follow DispatchQueue blocks): RowBitmaps, tiles, Markdown regions.
enum PaletteScope {
    /// The scope's palette for work inside a Swift task or off the main thread.
    @TaskLocal static var scoped: PaletteBox? = nil
    /// The palettes kept outside a task local, and `Fixture.baseGeneration`. The main thread writes them; render
    /// workers read the process palette and the base generation while the main thread sets them, so they sit behind
    /// one lock (a box is immutable, so a reader keeps the one it got).
    private struct Shared {
        /// `Fixture.baseGeneration`: bumped by an appearance or a colour space change.
        var baseGeneration = 0
        /// The scope's palette on the main thread outside any task (a layer's draw, a layout pass); a task local is
        /// not bound there for the reason `RenderScaleScope.mainThreadScoped` gives. Only the main thread uses it.
        var mainThreadScoped: PaletteBox?
        /// The process palette: `Fixture.theme` outside any scope.
        var process: PaletteBox?
        /// Every palette made, by theme: equal themes share a box and its id. Main thread only.
        var boxesByTheme: [FixtureTheme: PaletteBox] = [:]
    }
    // FixtureTheme keys are not Sendable: the lock is their only access path, so its unchecked state is safe.
    private static let shared = OSAllocatedUnfairLock(uncheckedState: Shared())

    /// The process palette: `Fixture.theme` outside any scope.
    static var process: PaletteBox? { shared.withLockUnchecked { $0.process } }
    /// `Fixture.baseGeneration` (any thread).
    static var baseGeneration: Int { shared.withLockUnchecked { $0.baseGeneration } }
    /// Bumps `Fixture.baseGeneration` (main thread: an appearance or a colour space change).
    static func bumpBaseGeneration() { shared.withLockUnchecked { $0.baseGeneration += 1 } }
    /// `Fixture.generation(of:)`: the base generation and the id of `box`, else of the process palette, read together.
    static func generation(of box: PaletteBox?) -> Int {
        shared.withLockUnchecked { $0.baseGeneration &* 1_000_003 &+ ((box ?? $0.process)?.id ?? 0) }
    }
    /// The palette of the scope that runs now, nil outside any scope.
    static var current: PaletteBox? {
        if let scoped { return scoped }
        guard Thread.isMainThread else { return nil }
        return shared.withLockUnchecked { $0.mainThreadScoped }
    }
    /// The palette drawing reads now: the scope's, else the process palette (one lock, not two).
    static var effective: PaletteBox? {
        if let scoped { return scoped }
        let onMain = Thread.isMainThread
        return shared.withLockUnchecked { (onMain ? $0.mainThreadScoped : nil) ?? $0.process }
    }

    /// The one box for `theme` (main thread).
    static func box(for theme: FixtureTheme) -> PaletteBox {
        dispatchPrecondition(condition: .onQueue(.main))
        return shared.withLockUnchecked { state in
            if let b = state.boxesByTheme[theme] { return b }
            let b = PaletteBox(theme, id: state.boxesByTheme.count + 1)
            state.boxesByTheme[theme] = b
            return b
        }
    }

    /// Sets the process palette (`Fixture.theme`'s setter): the palette outside any scope.
    static func setProcess(_ theme: FixtureTheme?) {
        let box = theme.map(box(for:))
        shared.withLockUnchecked { $0.process = box }
    }

    /// The chat the person typed or clicked in gives the process palette (its composer and send read it outside
    /// a scope).
    static func claimProcess(_ box: PaletteBox?) {
        guard let box else { return }
        shared.withLockUnchecked { if $0.process !== box { $0.process = box } }
    }

    /// Runs `body` with `box` as this thread's palette (nil: the current one stays).
    static func with<T>(_ box: PaletteBox?, _ body: () throws -> T) rethrows -> T {
        guard let box, current !== box else { return try body() }
        if Thread.isMainThread, !withUnsafeCurrentTask(body: { $0 != nil }) {
            let outer = shared.withLockUnchecked { state in
                defer { state.mainThreadScoped = box }
                return state.mainThreadScoped
            }
            defer { shared.withLockUnchecked { $0.mainThreadScoped = outer } }
            return try body()
        }
        // concurrency-allow: bound inside a task or off the main thread, never in fallback storage on main
        return try $scoped.withValue(box, operation: body)
    }

    /// The palette of the window view that shows the AppKit view `view` (its pane's HostView), nil outside one.
    static func palette(of view: NSView?) -> PaletteBox? {
        var v = view
        while let x = v {
            if let h = x as? HostView { return h.demo?.palette }
            v = x.superview
        }
        return nil
    }

    /// The palette of the window view that holds the ported view `view`, nil outside one.
    static func palette(of view: UIView?) -> PaletteBox? {
        var v = view
        while let x = v {
            if let w = x as? MessagesWindowView { return w.palette }
            v = x.superview
        }
        return nil
    }
}

extension FixtureTheme: Hashable {
    func hash(into h: inout Hasher) {
        h.combine(active.palette)
        h.combine(measuredAccent)
    }
}
