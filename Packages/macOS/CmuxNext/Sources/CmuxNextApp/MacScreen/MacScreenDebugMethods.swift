import AppKit
import CmuxNextControl
import CmuxNextMacScreen
import CmuxNextSettings
import CmuxScreenKit
import Foundation

/// `debug.mac_screen` (development builds): Mac Screen tabs and Share This
/// Mac, for live checks. Pairing links carry a room secret, so they move
/// only through files readable by this user (mode 0600), never in params,
/// results or logs.
/// - `state` (default): the saved Macs (names only), Share This Mac, and one
///   row per tab: URL, gate, phase, path, stats, picture size, displays.
/// - `pair` {link_file}: saves the Mac whose link is in `link_file` and opens it.
/// - `open` {url?, pane?}: opens `url` (default the home page) in a new tab.
/// - `connect` {tab?}: presses Connect on tabs that ask first (stands in for the person).
/// - `share` {enabled}: switches Share This Mac (stands in for the person);
///   `link_file` writes this Mac's link there (0600).
/// - `forget` {name}: forgets the saved Macs with that name.
struct MacScreenDebugMethods {
    let services: AppServices

    func register(on router: ControlRouter?) {
        #if DEBUG
        let services = self.services
        router?.register([
            .async("debug.mac_screen") { [weak services] call in
                guard let services else { return .null }
                return await macScreenDebug(call.params, services: services)
            },
        ])
        #endif
    }
}

#if DEBUG
@MainActor
private func macScreenDebug(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
    let pages = services.macScreenPages
    let only = params["tab"]?.stringValue
    let tabs = MacScreenPageTab.live.allObjects.filter { only == nil || $0.id.rawValue == only }
    func openTab(_ url: URL) -> JSONValue {
        let named = params["pane"]?.stringValue.flatMap { key in
            services.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first
        }
        guard let pane = named ?? services.windows.active?.focusedPane ?? services.windows.controllers.first?.focusedPane else {
            return ["error": "no pane"]
        }
        pane.newBrowserTab(url: url)
        return ["opened": .string(url.absoluteString)]
    }
    switch params["action"]?.stringValue ?? "state" {
    case "pair":
        guard let path = params["link_file"]?.stringValue, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ["error": "link_file must name a readable file"]
        }
        switch pages.store.add(link: text) {
        case let .success(mac): return openTab(MacScreenRecord(macID: mac.id).url)
        case let .failure(error): return ["error": .string("\(error)")]
        }
    case "open":
        let url = params["url"]?.stringValue.flatMap(URL.init(string:)) ?? MacScreenRecord.homeURL
        guard MacScreenRecord.matches(url) else { return ["error": "url must be a cmux://mac-screen record"] }
        return openTab(url)
    case "connect":
        var pressed = 0
        for tab in tabs where tab.pane?.model.gate == .confirm {
            tab.pane?.debugConfirm()
            pressed += 1
        }
        return ["pressed": .number(Double(pressed))]
    case "share":
        if let enabled = params["enabled"]?.boolValue { pages.host.setEnabled(enabled) }
        if let path = params["link_file"]?.stringValue, let link = pages.host.link {
            FileManager.default.createFile(atPath: path, contents: Data(link.absoluteString.utf8), attributes: [.posixPermissions: 0o600])
        }
        return hostState(pages.host)
    case "forget":
        guard let name = params["name"]?.stringValue else { return ["error": "name required"] }
        let matches = pages.store.macs.filter { $0.name == name }
        for mac in matches { pages.store.forget(mac.id) }
        return ["forgotten": .number(Double(matches.count))]
    case "state":
        let rows: [JSONValue] = tabs.map { tab in
            var row: [String: JSONValue] = ["tab": .string(tab.id.rawValue), "url": .string(tab.record.url.absoluteString)]
            if let pane = tab.pane {
                row["gate"] = .string("\(pane.model.gate)")
                row["has_frame"] = .bool(pane.model.hasFrame)
                row["captures_keyboard"] = .bool(pane.model.capturesKeyboard)
                row["displays"] = .array(pane.model.displays.map { .string("\(Int($0.width))x\(Int($0.height))") })
                row["current_display"] = .number(Double(pane.model.currentDisplay))
                if let session = pane.session {
                    row["phase"] = .string(phaseName(session.phase))
                    row["reconnecting"] = .bool(session.isReconnecting)
                    row["path"] = .string(session.streamPath)
                    row["fps"] = .number(session.stats.fps)
                    row["rtt_ms"] = session.stats.latencyMs.map(JSONValue.number) ?? .null
                    row["encoding"] = .string(session.stats.encoding)
                    row["frame"] = .string("\(Int(session.frameSize.width))x\(Int(session.frameSize.height))")
                    row["quality"] = .string(session.preferences.quality.rawValue)
                }
                row["video_frame"] = .string(NSStringFromRect(pane.view.debugVideoFrame))
            }
            return .object(row)
        }
        return [
            "macs": .array(pages.store.macs.map { .string($0.name) }),
            "share": hostState(pages.host),
            "tabs": .array(rows),
        ]
    default:
        return ["error": "unknown action"]
    }
}

@MainActor
private func hostState(_ host: MacScreenShareHost) -> JSONValue {
    [
        "enabled": .bool(host.isEnabled), "status": .string("\(host.status)"),
        "screen_recording": .bool(host.screenRecordingGranted), "accessibility": .bool(host.accessibilityGranted),
        "has_link": .bool(host.link != nil),
    ]
}

private func phaseName(_ phase: ScreenSession.Phase) -> String {
    switch phase {
    case .connecting: "connecting"
    case .connected: "connected"
    case let .failed(message, _): "failed: \(message)"
    case .ended: "ended"
    }
}
#endif
