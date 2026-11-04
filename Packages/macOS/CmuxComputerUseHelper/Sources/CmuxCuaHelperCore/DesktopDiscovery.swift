// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation

/// One running regular app, as the OS names it (never the agent's words).
struct DiscoveredApp: Sendable, Equatable {
    let pid: Int32
    let name: String
    let bundleID: String
}

/// One layer-0 window: its number and owning pid, nothing else.
struct DiscoveredWindow: Sendable, Equatable {
    let windowID: UInt32
    let pid: Int32
}

/// How the worker enumerates the desktop before an app is allowed (injected in tests).
protocol DesktopEnumerating: Sendable {
    func runningApps() -> [DiscoveredApp]
    func windows() -> [DiscoveredWindow]
}

/// WindowServer's layer-0 windows and the regular apps that own them. Reads
/// the owner pid and window number only: never `kCGWindowName`, never pixels.
/// Apps come from the window owners (one `NSRunningApplication` per pid), not
/// from a process list: cmux never scans processes, and an app with no window
/// has nothing to act on.
struct MacDesktopEnumerator: DesktopEnumerating {
    func runningApps() -> [DiscoveredApp] {
        var seen = Set<Int32>()
        return windows().compactMap { window in
            guard seen.insert(window.pid).inserted,
                  // NSRunningApplication documents atomic, thread-safe property access.
                  let app = NSRunningApplication(processIdentifier: window.pid),
                  app.activationPolicy == .regular, !app.isTerminated,
                  let bundleID = app.bundleIdentifier else { return nil }
            return DiscoveredApp(pid: window.pid, name: app.localizedName ?? bundleID, bundleID: bundleID)
        }
    }

    func windows() -> [DiscoveredWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let number = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            return DiscoveredWindow(windowID: number, pid: pid)
        }
    }
}

/// Discovery before approval (docs/computer-use-approvals.md, "Discovery
/// before approval"; decision D21). Under `ask`, and under `bounded` for apps
/// outside the owner's manifest, upstream refuses `list_apps` and an unscoped
/// `list_windows` (the session manifest has `desktop.display: false`), so an
/// agent could never name an app and reach the approval question. The worker
/// answers those calls itself with metadata only: app name, bundle id, pid,
/// window id. Never-allowed apps (`CuaTargetPolicy`) are left out.
struct DesktopDiscovery: Sendable {
    /// What the result tells the agent about the missing titles.
    static let titlesHidden = "hidden until you are allowed to use the app"
    static let howToTarget = "Titles, screenshots and input need the person's approval of that app: "
        + "call the tool you need with its pid (and window_id); the first call on an app asks the person (on a box set up by its owner, an app outside the owner's list is refused instead)."

    /// The discovery call the worker answers.
    enum Call: Equatable {
        case apps
        /// Every window, or one pid's.
        case windows(pid: Int32?)
    }

    let enumerator: any DesktopEnumerating
    let policy: CuaTargetPolicy

    func answer(_ call: Call) -> Data {
        switch call {
        case .apps: listApps()
        case .windows(let pid): listWindows(pid: pid)
        }
    }

    /// The apps the policy may ask about, one per pid, by name.
    func allowedApps() -> [DiscoveredApp] {
        var seen = Set<Int32>()
        return enumerator.runningApps()
            .filter { policy.allows(bundleID: $0.bundleID, appName: $0.name) && seen.insert($0.pid).inserted }
            .sorted { ($0.name.lowercased(), $0.pid) < ($1.name.lowercased(), $1.pid) }
    }

    func listApps() -> Data {
        let apps = allowedApps()
        var text = "Found \(apps.count) running app(s). Window titles are \(Self.titlesHidden).\n"
        for app in apps { text += "  pid=\(app.pid) \(app.name) (\(app.bundleID))\n" }
        text += Self.howToTarget
        let entries: [[String: Any]] = apps.map {
            ["pid": Int($0.pid), "name": $0.name, "bundle_id": $0.bundleID, "running": true]
        }
        return Self.result(text: text, structured: ["apps": entries, "titles": Self.titlesHidden, "source": "cmux"])
    }

    func listWindows(pid: Int32?) -> Data {
        let apps = Dictionary(allowedApps().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UInt32>()
        let rows: [(DiscoveredWindow, DiscoveredApp)] = enumerator.windows().compactMap { window in
            guard pid.map({ $0 == window.pid }) ?? true, let app = apps[window.pid],
                  seen.insert(window.windowID).inserted else { return nil }
            return (window, app)
        }
        var text = "Found \(rows.count) window(s). Titles are \(Self.titlesHidden).\n"
        for (window, app) in rows { text += "  window_id=\(window.windowID) pid=\(window.pid) app=\(app.name)\n" }
        text += Self.howToTarget
        let entries: [[String: Any]] = rows.map { window, app in
            ["window_id": Int(window.windowID), "pid": Int(window.pid), "app_name": app.name, "bundle_id": app.bundleID]
        }
        return Self.result(text: text, structured: ["windows": entries, "titles": Self.titlesHidden, "source": "cmux"])
    }

    /// Shaped like upstream's tool results: MCP `content` text plus `structuredContent`.
    static func result(text: String, structured: [String: Any]) -> Data {
        let object: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "isError": false,
            "structuredContent": structured,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// What the worker needs from a `bounded` owner's manifest: its apps and
/// whether it grants desktop display (then upstream answers discovery). Nil
/// when the manifest is not JSON: the worker cannot tell, so upstream answers.
struct OwnerManifestFacts: Sendable, Equatable {
    let bundleIDs: Set<String>
    let display: Bool
    /// The manifest's `allow.tools`: discovery is answered only for those (review 3 #2).
    let tools: Set<String>

    init(bundleIDs: Set<String>, display: Bool, tools: Set<String> = ["list_apps", "list_windows"]) {
        self.bundleIDs = bundleIDs
        self.display = display
        self.tools = tools
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let resources = object["resources"] as? [String: Any] ?? [:]
        let apps = resources["apps"] as? [[String: Any]] ?? []
        bundleIDs = Set(apps.compactMap { ($0["bundle_id"] as? String)?.lowercased() })
        display = ((resources["desktop"] as? [String: Any])?["display"] as? Bool) == true
        tools = Set(((object["allow"] as? [String: Any])?["tools"] as? [String]) ?? [])
    }

    init?(path: String?) {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        self.init(data: data)
    }
}
