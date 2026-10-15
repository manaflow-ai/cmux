public import CmuxNextControl
public import Foundation
#if DEBUG
import AppKit
public import CmuxNextSettings
import CmuxScreenKit

/// `debug.mac_screen` (development builds): Mac Screen tabs and Share This
/// Mac, for live checks. Pairing links carry a room secret, so they move
/// only through files readable by this user (mode 0600), never in params,
/// results or logs.
/// - `state` (default): the saved Macs (names only), Share This Mac, and one
///   row per tab: URL, route, store tab id (null: app-only, not restored),
///   gate, phase, path, stats, picture size, displays;
///   `system_shortcuts` (the setting), `system_shortcuts_tap` (the tap is
///   installed) and `accessibility` (this Mac trusts cmux for Accessibility).
/// - `pair` {link_file}: saves the Mac whose link is in `link_file` and opens it.
/// - `open` {url?, pane?}: opens the record at `url` (default the home page) in a new Mac Screen tab.
/// - `connect` {tab?}: presses Connect on tabs that ask first (stands in for the person).
/// - `share` {enabled}: switches Share This Mac (stands in for the person);
///   `link_file` writes this Mac's link there (0600).
/// - `forget` {name}: forgets the saved Macs with that name.
extension MacScreenPages {
    /// Registers `debug.mac_screen` (development builds; nothing in Release).
    /// `openTab` opens a record in a new Mac Screen tab of the named pane (or
    /// the focused one), unconfirmed, and returns nil, or an error.
    public func registerDebug(on router: ControlRouter?, openTab: @escaping @MainActor (MacScreenRecord, String?) -> String?) {
        router?.register([
            .async("debug.mac_screen") { [weak self] call in
                guard let self else { return .null }
                return await debug(call.params, openTab: openTab)
            },
        ])
    }

    /// `openTab` opens a record in a new Mac Screen tab of the named pane (or the focused one); nil on success, else an error.
    public func debug(_ params: [String: JSONValue], openTab: @MainActor (MacScreenRecord, String?) -> String?) async -> JSONValue {
        let only = params["tab"]?.stringValue
        let tabs = self.tabs.values.filter { only == nil || $0.key == only }.sorted { $0.key < $1.key }
        func open(_ url: URL) -> JSONValue {
            if let error = openTab(MacScreenRecord(url: url) ?? MacScreenRecord(macID: nil), params["pane"]?.stringValue) { return ["error": .string(error)] }
            return ["opened": .string(url.absoluteString)]
        }
        switch params["action"]?.stringValue ?? "state" {
        case "pair":
            guard let path = params["link_file"]?.stringValue,
                  let text = await Task.detached(operation: { try? String(contentsOfFile: path, encoding: .utf8) }).value else {
                return ["error": "link_file must name a readable file"]
            }
            switch store.add(link: text) {
            case let .success(mac): return open(MacScreenRecord(macID: mac.id).url)
            case let .failure(error): return ["error": .string("\(error)")]
            }
        case "open":
            let url = params["url"]?.stringValue.flatMap(URL.init(string:)) ?? MacScreenRecord.homeURL
            guard MacScreenRecord.matches(url) else { return ["error": "url must be a cmux://mac-screen record"] }
            return open(url)
        case "connect":
            var pressed = 0
            for tab in tabs where tab.pane?.model.gate == .confirm {
                tab.pane?.debugConfirm()
                pressed += 1
            }
            return ["pressed": .number(Double(pressed))]
        case "share":
            if let enabled = params["enabled"]?.boolValue { host.setEnabled(enabled) }
            if let path = params["link_file"]?.stringValue, let link = host.link {
                let data = Data(link.absoluteString.utf8)
                await Task.detached {
                    FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
                }.value
            }
            return hostState
        case "forget":
            guard let name = params["name"]?.stringValue else { return ["error": "name required"] }
            let matches = store.macs.filter { $0.name == name }
            for mac in matches { store.forget(mac.id) }
            return ["forgotten": .number(Double(matches.count))]
        case "state":
            systemShortcuts.refreshAccessibility()
            return [
                "macs": .array(store.macs.map { .string($0.name) }),
                "share": hostState,
                "relay_only": .bool(relayOnly),
                // Send System Shortcuts to the Remote Mac: the setting, the tap, and this Mac's Accessibility.
                "system_shortcuts": .bool(systemShortcuts.enabled),
                "system_shortcuts_tap": .bool(systemShortcuts.tapInstalled),
                "accessibility": .bool(systemShortcuts.accessibilityGranted),
                "tabs": .array(tabs.map(row)),
            ]
        default:
            return ["error": "unknown action"]
        }
    }

    private var hostState: JSONValue {
        [
            "enabled": .bool(host.isEnabled), "status": .string("\(host.status)"), "indicator": .bool(host.indicatorVisible),
            "screen_recording": .bool(host.screenRecordingGranted), "accessibility": .bool(host.accessibilityGranted),
            "has_link": .bool(host.link != nil),
        ]
    }

    private func row(_ tab: MacScreenTab) -> JSONValue {
        var row: [String: JSONValue] = ["tab": .string(tab.key), "url": .string(tab.record.url.absoluteString),
                                        "route": route(for: tab.key).map(JSONValue.string) ?? .null,
                                        "store_tab": events.storeTabID(tab.key).map(JSONValue.string) ?? .null]
        guard let pane = tab.pane else { return .object(row) }
        row["gate"] = .string("\(pane.model.gate)")
        row["card"] = pane.model.card.map { .string("\($0)") } ?? .null
        row["has_frame"] = .bool(pane.model.hasFrame)
        row["relay_only"] = .bool(pane.model.relayOnly)
        row["captures_keyboard"] = .bool(pane.model.capturesKeyboard)
        row["displays"] = .array(pane.model.displays.map { .string("\(Int($0.width))x\(Int($0.height))") })
        row["current_display"] = .number(Double(pane.model.currentDisplay))
        row["video_frame"] = .string(NSStringFromRect(pane.view.debugVideoFrame))
        if let session = pane.session {
            row["phase"] = .string(Self.phaseName(session.phase))
            row["reconnecting"] = .bool(session.isReconnecting)
            row["path"] = .string(session.streamPath)
            row["fps"] = .number(session.stats.fps)
            row["rtt_ms"] = session.stats.latencyMs.map(JSONValue.number) ?? .null
            row["encoding"] = .string(session.stats.encoding)
            row["frame"] = .string("\(Int(session.frameSize.width))x\(Int(session.frameSize.height))")
            row["quality"] = .string(session.preferences.quality.rawValue)
        }
        return .object(row)
    }

    private static func phaseName(_ phase: ScreenSession.Phase) -> String {
        switch phase {
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        case .ended: "ended"
        }
    }
}
#else
extension MacScreenPages {
    public func registerDebug(on router: ControlRouter?, openTab: @escaping @MainActor (MacScreenRecord, String?) -> String?) {}
}
#endif
