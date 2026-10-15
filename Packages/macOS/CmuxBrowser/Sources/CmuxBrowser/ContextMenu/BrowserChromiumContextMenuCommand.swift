import Foundation

/// Chromium content context menu command ids cmux handles specially
/// (`chrome/app/chrome_command_ids.h`).
public enum BrowserChromiumContextMenuCommand: Int, Hashable, Sendable, CaseIterable {
    /// "Open Link in New Tab": Chromium asks the host for a tab, which cmux opens in the pane.
    case openLinkInNewTab = 50100
    /// "Open Link in New Window": the CEF shim removes it; cmux has no Chromium windows.
    case openLinkInNewWindow = 50101
    /// "Open Link in Incognito Window": Classic has no incognito windows.
    case openLinkOffTheRecord = 50102
    /// "Copy Link Address".
    case copyLinkLocation = 50104

    /// Commands a Classic Chromium menu never shows.
    public static let hiddenInClassic: Set<Int> = [
        BrowserChromiumContextMenuCommand.openLinkInNewWindow.rawValue,
        BrowserChromiumContextMenuCommand.openLinkOffTheRecord.rawValue,
    ]
}
