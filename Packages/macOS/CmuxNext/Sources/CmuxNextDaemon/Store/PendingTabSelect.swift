/// The tab a pane selects once the daemon reports it: one this app just created there (`surface`) or reopened there
/// (`tab`, its resource id). A pane's view state; its apply takes it the first time its tabs list it (``take(shown:record:)``).
public struct PendingTabSelect: Sendable {
    /// A created tab's surface: selected once the pane's shown tabs list it.
    public var surface: SurfaceID?
    /// A tab named by its resource id (a reopened tab's restored view): selected once the pane's record lists it.
    public var tab: String?

    public init(surface: SurfaceID? = nil, tab: String? = nil) {
        self.surface = surface
        self.tab = tab
    }

    /// The tab to select now, which then waits no more: the surface's tab once `shown` lists it, else the tab once
    /// `record` lists it. Nil while neither does; both stay as they were then.
    @MainActor public mutating func take(shown: [TabModel], record: [TabModel]) -> String? {
        if let surface, let made = shown.first(where: { $0.surface == surface }) {
            self.surface = nil
            return made.id
        }
        if let tab, record.contains(where: { $0.id == tab }) {
            self.tab = nil
            return tab
        }
        return nil
    }

    /// The hand-over of Cmd-N's stand-in pane to the daemon's pane that takes it over under another layout id, so under a
    /// new pane controller (P0 STATUS 13438): what the stand-in waited to select (`standIn`), else the tab it showed
    /// selected (`selected`, as the daemon's tab in its place once the records list one: `replacement`). One value, the
    /// waiting surface first, as ``take(shown:record:)`` takes them: a second would select later what nobody chose then.
    public mutating func takeOver(_ standIn: PendingTabSelect, selected: String?, replacement: (String) -> String?) {
        if let surface = standIn.surface {
            self = PendingTabSelect(surface: surface)
        } else if let tab = standIn.tab ?? selected.map({ replacement($0) ?? $0 }) {
            self = PendingTabSelect(tab: tab)
        }
    }
}
