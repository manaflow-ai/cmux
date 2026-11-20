public import AppKit
public import CmuxNextActions

extension PaletteController {
    /// Every action the Commands palette (Cmd-Shift-P) lists and could run now, in its order.
    ///
    /// Built from the palette's own registry rows (``makeRegistryProvider()``), with the same
    /// hidden ids, availability and overrides, so another surface's list (the New Tab page's
    /// dropdown) matches the palette. Rows the palette shows dimmed (unavailable here) are
    /// left out: they would not run.
    public func commandEntries() -> [PaletteCommandEntry] {
        captureContext()
        return PaletteCommandListing.entries(makeRegistryProvider().makeItems())
    }

    /// ``commandEntries()`` read in pieces, for a list no one sees this frame (the New Tab page's bar): the context is
    /// captured now, and each ``PaletteCommandListing/step(until:)`` reads catalog actions until its deadline.
    public func commandListing() -> PaletteCommandListing {
        captureContext()
        return PaletteCommandListing(RegistryPaletteProvider.ItemsPass(makeRegistryProvider()))
    }

    /// Runs the Commands palette row for `id` as if it were picked there.
    ///
    /// A row that just runs (most actions) runs without showing the palette. A row that needs
    /// more (an action's arguments, a nested list, a name to type) opens the palette on that
    /// step, so the person finishes it there, as they would after picking it in the palette.
    /// - Parameters:
    ///   - id: The action to run; it must be one of ``commandEntries()``.
    ///   - window: The window the palette opens over when the row needs it.
    /// - Returns: false when the palette does not list `id` or lists it as unavailable.
    @discardableResult
    public func runCommand(_ id: ActionID, relativeTo window: NSWindow? = nil) -> Bool {
        captureContext()
        guard let item = makeRegistryProvider().makeItems().first(where: { $0.actionID == id }), item.isEnabled else { return false }
        // Decided once: an argument page is built here, not again by the palette.
        let effect = item.primary.effect.resolved()
        switch effect {
        case .perform(let handler), .performKeepingOpen(let handler):
            if let key = item.frecencyKey { model.recordUse(key) }
            handler()
        case .push, .replace, .textInput, .deferred:
            show(.commands, relativeTo: window)
            let primary = item.primary
            model.run(PaletteCommand(id: primary.id, title: primary.title, symbol: primary.symbol, effect: effect), of: item)
        }
        return true
    }
}

/// One ``PaletteController/commandEntries()`` read a few catalog actions at a time (``PaletteController/commandListing()``).
///
/// Each action's shown state (its title, why it cannot run, its shortcut) is read on the main actor, hundreds of
/// actions in all (7-10 ms, PACING TRIAGE #32910). A list no one sees this frame reads them in pieces on the
/// main thread's budgeted work, as Chrome's scheduler runs best-effort tasks in the idle time of each frame:
///
/// ```swift
/// let listing = palette.commandListing()
/// while (listing.step(until: .now + .microseconds(500))) == nil { await nextFrame() }
/// ```
@MainActor
public final class PaletteCommandListing {
    private let pass: RegistryPaletteProvider.ItemsPass
    private var allRead = false

    init(_ pass: RegistryPaletteProvider.ItemsPass) {
        self.pass = pass
    }

    /// Reads catalog actions until `deadline` (at least one per call); the call after the last read arranges them.
    /// Each action's state is read when its slice comes, so a list read over several frames can mix the states of
    /// those frames (the focused object can change meanwhile); the next listing reads them again.
    ///
    /// - Parameter deadline: When to stop reading.
    /// - Returns: The entries, as ``PaletteController/commandEntries()`` lists them, once every action is read and
    ///   arranged; nil while some work is left (call again on a later frame).
    public func step(until deadline: ContinuousClock.Instant) -> [PaletteCommandEntry]? {
        guard allRead else {
            var read = 0
            allRead = pass.read(while: {
                read += 1
                return read == 1 || ContinuousClock.now < deadline
            })
            return nil
        }
        return Self.entries(pass.finish())
    }

    /// The palette rows that run now, as command entries.
    static func entries(_ items: [PaletteItem]) -> [PaletteCommandEntry] {
        items.compactMap { item in
            guard item.isEnabled, let id = item.actionID else { return nil }
            return PaletteCommandEntry(id: id, title: item.title, section: item.section.title, keywords: item.keywords,
                                       keycaps: item.keycaps ?? [], symbol: item.symbol)
        }
    }
}
