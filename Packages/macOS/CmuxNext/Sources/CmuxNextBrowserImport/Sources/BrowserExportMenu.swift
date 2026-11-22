/// The browser menu of Import from Another Browser…, ordered for one Mac.
///
/// The browsers on this Mac come first (in the file's order), then the rest; the default web browser is
/// chosen, else the first one on this Mac. The caller answers which bundle ids are installed and which
/// is the default (Launch Services); no browser data is read.
///
/// ```swift
/// let menu = BrowserExportMenu(rows: BrowserExportSource.all,
///                              isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
///                              defaultBrowserBundleID: "net.imput.helium")
/// ```
public nonisolated struct BrowserExportMenu: Sendable {
    /// Every row, the installed ones first.
    public let rows: [BrowserExportSource]
    /// The row the menu starts on; nil only when there are no rows.
    public let selected: BrowserExportSource?

    /// Orders `all` for one Mac.
    ///
    /// - Parameters:
    ///   - all: The rows, in the file's order.
    ///   - isInstalled: Whether an app with this bundle id is on this Mac.
    ///   - defaultBrowserBundleID: The default web browser's bundle id, if known.
    public init(rows all: [BrowserExportSource], isInstalled: (String) -> Bool, defaultBrowserBundleID: String?) {
        let installed = all.filter { $0.bundleIDs.contains(where: isInstalled) }
        let installedIDs = Set(installed.map(\.id))
        rows = installed + all.filter { !installedIDs.contains($0.id) }
        let preferred = defaultBrowserBundleID.flatMap { id in installed.first { $0.bundleIDs.contains(id) } }
        selected = preferred ?? installed.first ?? rows.first
    }
}
