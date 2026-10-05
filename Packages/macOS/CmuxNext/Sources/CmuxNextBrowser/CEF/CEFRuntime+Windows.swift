import AppKit
import Foundation

/// C entry for the fork's window requests (main thread, possibly inside a
/// Chromium navigation). Returns the anchor browser of the pane window that
/// gets the new tab, or 0 when Chromium must open nothing.
let cefWindowRequestCallback: CEFShimLibrary.WindowRequestFn = { context, kind, disposition, source, hasBounds,
    x, y, width, height, userGesture, url, profile in
    guard let context, Thread.isMainThread else { return 0 }
    let request = CEFWindowRequest(
        kind: CEFWindowRequest.Kind(rawValue: kind) ?? .window,
        disposition: CEFDisposition(raw: Int(disposition)),
        sourceBrowser: source,
        bounds: hasBounds != 0 ? CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)) : nil,
        url: url.map { String(cString: $0) } ?? "",
        userGesture: userGesture != 0,
        profilePath: CEFRuntime.normalizedPath(profile.map { String(cString: $0) } ?? "")
    )
    let address = UInt(bitPattern: context)
    return MainActor.assumeIsolated {
        CEFRuntime.from(address)?.windowRequests.handle(request) ?? 0
    }
}

/// Window requests so far and what became of them (`debug.cef`).
nonisolated struct CEFWindowRequestLog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var request: CEFWindowRequest
        var decision: CEFWindowDecision
    }

    private(set) var count = 0
    private(set) var refused = 0
    /// Chromium commands that would open a Chromium window, blocked by the shim.
    private(set) var blockedCommands: [Int32] = []
    private(set) var recent: [Entry] = []
    /// The latest popup window steps (fork API 13), for `debug.cef`.
    private(set) var popupWindows: [String] = []

    mutating func notePopupWindow(_ event: String) {
        popupWindows.append(event)
        if popupWindows.count > 12 { popupWindows.removeFirst(popupWindows.count - 12) }
    }

    mutating func record(_ request: CEFWindowRequest, _ decision: CEFWindowDecision) {
        count += 1
        if case .refuse = decision { refused += 1 }
        recent.append(Entry(request: request, decision: decision))
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
    }

    mutating func blocked(command: Int32) {
        blockedCommands.append(command)
        if blockedCommands.count > 8 { blockedCommands.removeFirst(blockedCommands.count - 8) }
    }
}

extension CEFRuntime {
    /// Chromium's `IDC_NEW_INCOGNITO_WINDOW`.
    static let newIncognitoWindowCommand: Int32 = 34001

    /// A pane window's store, compared with request stores.
    func storeKey(of key: CEFPaneKey) -> String {
        let context = contextKey(for: key)
        return key.offTheRecord ? context : Self.normalizedPath(context)
    }

    /// How the next tab inserted into `window` opens: the oldest placement a
    /// window request recorded for it, else `fallback` with the popup
    /// features Chromium reported at creation.
    func takePlacement(window: Int32, fallback: BrowserNewTabDisposition, created: CEFCreatedBy = .none) -> CEFPlacement {
        guard var placement = placements.take(window: window) else {
            return CEFPlacement(disposition: fallback, bounds: created.features)
        }
        placement.bounds = CEFPlacement.resolvedBounds(request: placement.bounds, created: created.features)
        return placement
    }

    /// Chromium reports the profile directory; compare it with ours the same
    /// way.
    nonisolated static func normalizedPath(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The shim blocked a Chromium command that opens a Chromium window.
    func chromeWindowCommandBlocked(_ command: Int32, browser: Int32) {
        windowRequests.log.blocked(command: command)
        logger.notice("Blocked Chromium command \(command) (it opens a Chromium window)")
        if command == Self.newIncognitoWindowCommand {
            // New Incognito Window (Cmd-Shift-N in a page when cmux
            // does not bind it): a new cmux incognito window.
            Task { @MainActor [weak self] in self?.openOffTheRecord?(nil, nil) }
        }
    }

    func refused(_ refusal: CEFWindowRefusal, source: Int32) {
        switch refusal {
        case .noWindow:
            logger.notice("Chromium window request from a store with no window refused (source=\(source))")
        }
    }

    /// Undocked DevTools cmux opened on purpose (its own window).
    func isPlacedDevToolsWindow(_ window: NSWindow) -> Bool {
        guard window.title.hasPrefix("DevTools") else { return false }
        return tabsByBrowser.values.contains { $0.devTools.isOpen && !$0.devTools.dock.isDocked }
    }
}

/// Chromium never opens a window of its own: what happened so far
/// (`debug.cef` `windows`). A live check expects `chromiumWindows` empty.
public struct CEFWindowReport: Sendable {
    /// Window requests the fork sent (fork API 8).
    public var requests: Int
    public var refused: Int
    /// The latest requests: "kind=… disposition=… source=… -> decision".
    public var recent: [String]
    /// Chromium commands the shim blocked (`IDC_*` ids).
    public var blockedCommands: [Int32]
    /// Browsers Chromium created outside cmux (fork API 8), or -1.
    public var foreignBrowsers: Int
    /// Windows the app's guard hid or closed, and the latest of them.
    public var guardBlocked: Int
    public var guardRecent: [String]
    /// Top-level Chromium windows with a title bar on screen now.
    public var chromiumWindows: [String]
    /// Tabs Chromium created that wait for a pane window.
    public var unplacedTabs: Int
    public var forkAPIVersion: Int
    /// The latest popup window events (fork API 13).
    public var popupWindows: [String] = []
}

extension CEFRuntime {
    var windowReport: CEFWindowReport {
        let started = state == .ready
        return CEFWindowReport(
            requests: windowRequests.log.count,
            refused: windowRequests.log.refused,
            recent: windowRequests.log.recent.map { entry in
                "kind=\(entry.request.kind.rawValue) disposition=\(entry.request.disposition.rawValue) source=\(entry.request.sourceBrowser) -> \(entry.decision)"
            },
            blockedCommands: windowRequests.log.blockedCommands,
            foreignBrowsers: started ? Int(shim?.foreignBrowserCount() ?? -1) : -1,
            guardBlocked: windowGuard.blockedCount,
            guardRecent: windowGuard.recent.map { "\($0.verdict) \($0.className) \"\($0.title)\"" },
            chromiumWindows: started ? windowGuard.offendingWindows().map { "\(NSStringFromClass(type(of: $0))) \"\($0.title)\"" } : [],
            unplacedTabs: orphans.unplaced.count,
            forkAPIVersion: Int(forkAPIVersion),
            popupWindows: windowRequests.log.popupWindows
        )
    }
}
