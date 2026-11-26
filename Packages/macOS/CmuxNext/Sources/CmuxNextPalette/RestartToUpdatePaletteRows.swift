public import CmuxNextActions

/// Restart to Update in the Command Palette (Lawrence 2026-11-16: "we need cmd shift p restart to update").
///
/// While a downloaded update waits, the palette lists one "Restart to Update" row, found by restart,
/// update, relaunch or upgrade, that runs the install the sidebar card's Restart to Update and the app
/// menu run (`palette.applyUpdateIfAvailable`). While it waits, the install rows step aside; Check for
/// Updates… stays listed (Leo 2026-11-22: typing "check for update" found only a setting), since a check
/// while an update waits still looks for a newer build. With none waiting there is no row. The updater owns what waits and the row's localized title
/// (`UpdaterService.restartableUpdate`); this type only lists it.
///
/// ```swift
/// RestartToUpdatePaletteRows(staged: { [weak updater] in updater?.restartableUpdate.map { ($0.title, $0.version) } })
///     .install(into: palette, registry: registry)
/// ```
public struct RestartToUpdatePaletteRows {
    /// What waits: the row's title (the sidebar card's button title, localized) and the staged version.
    public typealias Staged = (title: String, version: String?)

    /// The row's id and frecency key.
    public static let rowID = "updates.restartToUpdate"
    /// The install every Restart to Update runs.
    static let installAction: ActionID = "palette.applyUpdateIfAvailable"
    /// The catalog rows the staged update's row stands in for while it waits.
    static let replacedWhileStaged: Set<ActionID> = ["palette.applyUpdateIfAvailable", "palette.attemptUpdate"]
    /// Words the row is found by beside its title (English, like the catalog's keywords).
    static let keywords = ["restart", "update", "relaunch", "upgrade", "install", "new version"]

    /// The update that waits now, read on each palette open.
    let staged: @MainActor () -> Staged?

    /// Makes the rows over the updater's waiting update.
    /// - Parameter staged: Reads the update that waits now; nil lists no row and hides nothing.
    public init(staged: @escaping @MainActor () -> Staged?) {
        self.staged = staged
    }

    /// The catalog rows to leave out of this palette open.
    @MainActor func hiddenActionIDs() -> Set<ActionID> {
        staged() == nil ? [] : Self.replacedWhileStaged
    }

    /// The row while an update waits, else none; `perform` runs the install.
    @MainActor func rows(perform: @escaping @MainActor (ActionInvocation) -> Void) -> [PaletteItem] {
        guard let update = staged() else { return [] }
        var item = PaletteItem(
            id: Self.rowID,
            title: update.title,
            subtitle: update.version,
            symbol: "arrow.clockwise.circle",
            section: RegistryPaletteProvider.section(for: .settings),
            keywords: Self.keywords,
            primary: PaletteCommand(id: "restart", title: update.title, symbol: "return", effect: .perform {
                perform(ActionInvocation(origin: .user))
            }),
            frecencyKey: Self.rowID,
            // Ahead of an equal match while typing, as a daily catalog row is.
            rankBias: RegistryPaletteProvider.dailyRankBias
        )
        item.aliases = ["restart to update", "update and restart", "install update"]
        return [item]
    }

    /// Lists the row in `palette` (Cmd-Shift-P, Search) and hides the rows it stands in for while an update waits.
    /// - Parameters:
    ///   - palette: The app's palette; the rows it already hides stay hidden.
    ///   - registry: Runs the install when the row runs.
    @MainActor public func install(into palette: PaletteController, registry: ActionRegistry) {
        let hiddenBefore = palette.hiddenActionIDs
        palette.sources.extraProviders.append(provider(registry: registry))
        palette.hiddenActionIDs = { (hiddenBefore?() ?? []).union(self.hiddenActionIDs()) }
    }

    /// The root palette's provider, read on each open, listed for the empty query too.
    @MainActor func provider(registry: ActionRegistry) -> AsyncPaletteProvider {
        let action = Self.installAction
        return AsyncPaletteProvider(id: Self.rowID, showsItemsForEmptyQuery: true) { [weak registry] in
            guard let registry else { return [] }
            return rows { [weak registry] in _ = registry?.perform(action, invocation: $0) }
        }
    }
}
