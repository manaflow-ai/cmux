import AppKit

/// cmux: one window view's palette (its Home chat's theme and Chat Colors…), with a stable id that keys every
/// palette-dependent cache. Equal themes share one box (``PaletteScope/box(for:)``), so equal palettes share
/// their row bitmaps and tiles, and two chats with different colours never read each other's.
// Immutable after init; FixtureTheme holds NSColor and CGGradient values, which are safe to read from any thread.
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
    /// The scope's palette on the main thread outside any task (a layer's draw, a layout pass); a task local is not
    /// bound there for the reason `RenderScaleScope.mainThreadScoped` gives.
    // crash-allow: read and written only on the main thread (`with` and `current` check it).
    nonisolated(unsafe) private static var mainThreadScoped: PaletteBox? = nil
    /// The process palette: `Fixture.theme` outside any scope.
    // crash-allow: written on the main thread only (`Fixture.theme`'s setter, `claimProcess`); a box is immutable.
    nonisolated(unsafe) private(set) static var process: PaletteBox? = nil
    /// Every palette made, by theme: equal themes share a box and its id. Main thread only.
    // crash-allow: read and written only on the main thread (`box(for:)` asserts it).
    nonisolated(unsafe) private static var boxes: [FixtureTheme: PaletteBox] = [:]

    /// The palette of the scope that runs now, nil outside any scope.
    static var current: PaletteBox? { scoped ?? (Thread.isMainThread ? mainThreadScoped : nil) }
    /// The palette drawing reads now: the scope's, else the process palette.
    static var effective: PaletteBox? { current ?? process }

    /// The one box for `theme` (main thread).
    static func box(for theme: FixtureTheme) -> PaletteBox {
        dispatchPrecondition(condition: .onQueue(.main))
        if let b = boxes[theme] { return b }
        let b = PaletteBox(theme, id: boxes.count + 1)
        boxes[theme] = b
        return b
    }

    /// Sets the process palette (`Fixture.theme`'s setter): the palette outside any scope.
    static func setProcess(_ theme: FixtureTheme?) { process = theme.map(box(for:)) }

    /// The chat the person typed or clicked in gives the process palette (its composer and send read it outside
    /// a scope).
    static func claimProcess(_ box: PaletteBox?) {
        guard let box, process !== box else { return }
        process = box
    }

    /// Runs `body` with `box` as this thread's palette (nil: the current one stays).
    static func with<T>(_ box: PaletteBox?, _ body: () throws -> T) rethrows -> T {
        guard let box, current !== box else { return try body() }
        if Thread.isMainThread, !withUnsafeCurrentTask(body: { $0 != nil }) {
            let outer = mainThreadScoped
            mainThreadScoped = box
            defer { mainThreadScoped = outer }
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
