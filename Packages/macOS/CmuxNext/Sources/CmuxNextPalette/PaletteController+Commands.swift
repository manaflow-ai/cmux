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
        return makeRegistryProvider().makeItems().compactMap { item in
            guard item.isEnabled, let id = item.actionID else { return nil }
            return PaletteCommandEntry(id: id, title: item.title, section: item.section.title, keywords: item.keywords,
                                       keycaps: item.keycaps ?? [], symbol: item.symbol)
        }
    }

    /// Every row the Commands palette lists, as a catalog: catalog title, section, keywords and keycaps, with no
    /// availability or state (``PaletteCommandCatalog``). Built once per binding change, so a surface that lists it
    /// on every open (the New Tab page) builds nothing; its shown rows ask ``commandStates(_:)``.
    public func commandCatalog() -> [PaletteCommandEntry] {
        keptCommandCatalog.entries(registry, hidden: hiddenActionIDs?() ?? []) {
            let provider = makeRegistryProvider()
            provider.decidesRows = false
            return provider.makeItems().compactMap { item in
                guard let id = item.actionID else { return nil }
                return PaletteCommandEntry(id: id, title: item.title, section: item.section.title, keywords: item.keywords,
                                           keycaps: item.keycaps ?? [], symbol: item.symbol)
            }
        }
    }

    /// The rows of `ids` as the palette decides them now: whether each runs, and its current title. An id the
    /// palette does not list here is left out (the surface shows no row for it). The same code decides the
    /// palette's own rows, so a surface never offers a row the palette would show dimmed.
    public func commandStates(_ ids: Set<ActionID>) -> [ActionID: RegistryPaletteProvider.RowState] {
        captureContext()
        return makeRegistryProvider().states(of: ids)
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
