import AppKit
import Foundation

/// C entry for the fork's window requests (main thread, possibly inside a
/// Chromium navigation). Returns the anchor browser of the pane window that
/// gets the new tab, or 0 when Chromium must open nothing.
let cefWindowRequestCallback: CEFShimLibrary.WindowRequestFn = { context, kind, disposition, source, hasBounds,
    x, y, width, height, url, profile in
    guard let context, Thread.isMainThread else { return 0 }
    let request = CEFWindowRequest(
        kind: CEFWindowRequest.Kind(rawValue: kind) ?? .window,
        disposition: CEFDisposition(raw: Int(disposition)),
        sourceBrowser: source,
        bounds: hasBounds != 0 ? CGRect(x: Int(x), y: Int(y), width: Int(width), height: Int(height)) : nil,
        url: url.map { String(cString: $0) } ?? "",
        profilePath: CEFRuntime.normalizedPath(profile.map { String(cString: $0) } ?? "")
    )
    let address = UInt(bitPattern: context)
    return MainActor.assumeIsolated {
        CEFRuntime.from(address)?.windowRequested(request) ?? 0
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
    /// Chrome commands that would open a Chromium window, blocked by the shim.
    private(set) var blockedCommands: [Int32] = []
    private(set) var recent: [Entry] = []

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
    /// Chrome's `IDC_NEW_INCOGNITO_WINDOW`.
    static let newIncognitoWindowCommand: Int32 = 34001

    /// Where a Chromium window request goes (`CEFWindowPolicy`), applied.
    func windowRequested(_ request: CEFWindowRequest) -> Int32 {
        let decision = CEFWindowPolicy.decide(request, candidates: windowCandidates(for: request))
        windowRequestLog.record(request, decision)
        logger.notice("Chromium window request kind=\(request.kind.rawValue) disposition=\(request.disposition.rawValue) source=\(request.sourceBrowser) -> \(String(describing: decision), privacy: .public)")
        switch decision {
        case .insert(let anchor, let disposition):
            if let window = shim?.tabWindowID(anchor), window != 0 {
                placements[window, default: []].append(disposition)
            }
            return anchor
        case .openInNewTab(let url, let disposition):
            if let url = URL(string: url) {
                // Not from inside Chromium's navigation: the App creates a tab.
                Task { @MainActor [weak self] in self?.openURLWithoutWindow?(url, disposition) }
            }
            return 0
        case .openOffTheRecord:
            return 0
        case .refuse(let refusal):
            refused(refusal, source: request.sourceBrowser)
            return 0
        }
    }

    /// The first recorded disposition for the next tab inserted into
    /// `window` (by a window request), if any.
    func takePlacement(window: Int32) -> BrowserNewTabDisposition? {
        guard var queue = placements[window], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        placements[window] = queue.isEmpty ? nil : queue
        return first
    }

    func windowCandidates(for request: CEFWindowRequest) -> [CEFWindowCandidate] {
        let sourceHost = tabsByBrowser[request.sourceBrowser]?.host
        return hosts.values.compactMap { host in
            guard host.isLive, let anchor = host.anchorBrowser else { return nil }
            return CEFWindowCandidate(
                anchor: anchor,
                profilePath: Self.normalizedPath(storage.cachePath(for: host.key.profile).path),
                holdsSource: host === sourceHost,
                lastShown: host === lastShownHost,
                visible: host.hostView.window != nil && !host.hostView.isHiddenOrHasHiddenAncestor
            )
        }
        .sorted { $0.anchor < $1.anchor }
    }

    /// Chromium reports the profile directory; compare it with ours the same
    /// way.
    nonisolated static func normalizedPath(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The shim blocked a Chrome command that opens a Chromium window.
    func chromeWindowCommandBlocked(_ command: Int32, browser: Int32) {
        windowRequestLog.blocked(command: command)
        logger.notice("Blocked Chrome command \(command) (it opens a Chromium window)")
        if command == Self.newIncognitoWindowCommand { refused(.offTheRecord, source: browser) }
    }

    private func refused(_ refusal: CEFWindowRefusal, source: Int32) {
        switch refusal {
        case .offTheRecord:
            let tab = tabsByBrowser[source] ?? lastShownHost?.visibleTab
            tab?.emit(.notice(Strings.incognitoUnavailable))
        case .noWindow:
            break
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
    /// Chrome commands the shim blocked (`IDC_*` ids).
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
}

extension CEFRuntime {
    var windowReport: CEFWindowReport {
        let started = state == .ready
        return CEFWindowReport(
            requests: windowRequestLog.count,
            refused: windowRequestLog.refused,
            recent: windowRequestLog.recent.map { entry in
                "kind=\(entry.request.kind.rawValue) disposition=\(entry.request.disposition.rawValue) source=\(entry.request.sourceBrowser) -> \(entry.decision)"
            },
            blockedCommands: windowRequestLog.blockedCommands,
            foreignBrowsers: started ? Int(shim?.foreignBrowserCount() ?? -1) : -1,
            guardBlocked: windowGuard.blockedCount,
            guardRecent: windowGuard.recent.map { "\($0.verdict) \($0.className) \"\($0.title)\"" },
            chromiumWindows: started ? windowGuard.offendingWindows().map { "\(NSStringFromClass(type(of: $0))) \"\($0.title)\"" } : [],
            unplacedTabs: unplaced.count,
            forkAPIVersion: Int(forkAPIVersion)
        )
    }
}
