/// The one rule for which apps show their contributions (sidebar sections
/// and items, palette rows, menu rows, status items, widgets; D55): an app is
/// presented when it is installed, enabled and not hidden. It reads the app
/// supervisor's mirror through `AppsClient` (apps-list `installed`,
/// `enabled`, `hidden`, with pending changes applied), so every surface
/// agrees about a hidden app.
public nonisolated struct AppPresence: Sendable, Equatable {
    /// Apps whose contributions show.
    public var presented: Set<String>
    /// Apps installed but not presented (hidden or disabled): their
    /// contributions draw nothing, with no placeholder.
    public var suppressed: Set<String>

    public init(_ apps: [AppRecord]) {
        presented = Set(apps.filter(\.isVisible).map(\.id))
        suppressed = Set(apps.filter { $0.installed && !$0.isVisible }.map(\.id))
    }

    /// Not installed at all: the sidebar shows an "Install" placeholder
    /// for its section (a hidden app shows nothing).
    public func needsInstall(_ id: String) -> Bool { !presented.contains(id) && !suppressed.contains(id) }

    public func isPresented(_ id: String) -> Bool { presented.contains(id) }
}
