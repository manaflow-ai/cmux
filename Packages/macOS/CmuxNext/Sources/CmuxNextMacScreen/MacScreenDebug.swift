public import CmuxNextControl
public import Foundation
#if DEBUG
import AppKit
public import CmuxNextSettings
import CmuxScreenKit

/// `debug.mac_screen` (development builds): Mac Screen tabs, for live
/// checks. (Device hub sessions are `debug.device_hub`; link pairing is gone.)
/// - `state` (default): this Mac's sharing permissions, Relay Only, and one
///   row per tab: URL, route, store tab id (null: app-only, not restored),
///   gate, card, phase, path, stats, picture size, displays;
///   `system_shortcuts` (the setting), `system_shortcuts_tap` (the tap is
///   installed) and `accessibility` (this Mac trusts cmux for Accessibility).
/// - `open` {url?, pane?}: opens the record at `url` (default the home page) in a new Mac Screen tab.
/// - `display_fps` {fps?, tab?}: the refresh rate each tab (or `tab`)
///   reports to its Mac instead of its display's; no `fps` reports the
///   display's own again. Returns the tabs as `state` does.
/// - `quality` {quality, tab?}: the Quality menu's choice (auto, smooth,
///   low, medium, high) for each tab (or `tab`), as the menu sets it.
///
/// Each streaming row also has `target_fps` (the rate the Mac says it
/// streams at), `display_fps` (the rate this pane reported), and WebRTC's
/// totals `frames_received`, `frames_decoded`, `frames_dropped` and
/// `kilobytes_per_second`.
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
        case "open":
            let url = params["url"]?.stringValue.flatMap(URL.init(string:)) ?? MacScreenRecord.homeURL
            guard MacScreenRecord.matches(url) else { return ["error": "url must be a cmux://mac-screen record"] }
            return open(url)
        case "display_fps":
            let fps = params["fps"]?.intValue
            if let fps, !(1 ... 1000).contains(fps) { return ["error": "fps must be 1...1000"] }
            for tab in tabs { tab.pane?.view.debugDisplayFrameRate = fps }
            return ["tabs": .array(tabs.map(row))]
        case "quality":
            guard let quality = params["quality"]?.stringValue.flatMap(ScreenQuality.init(rawValue:)) else {
                return ["error": "quality: auto, smooth, low, medium, high"]
            }
            for tab in tabs { tab.pane?.view.chrome.actions.setQuality(quality) }
            return ["tabs": .array(tabs.map(row))]
        case "state":
            systemShortcuts.refreshAccessibility()
            return [
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
        ["screen_recording": .bool(host.screenRecordingGranted), "accessibility": .bool(host.accessibilityGranted)]
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
            row["target_fps"] = session.stats.targetFps.map { .number(Double($0)) } ?? .null
            row["display_fps"] = session.displayMaximumFrameRate.map { .number(Double($0)) } ?? .null
            row["frames_received"] = .number(session.stats.framesReceived)
            row["frames_decoded"] = .number(session.stats.framesDecoded)
            row["frames_dropped"] = .number(session.stats.framesDropped)
            row["kilobytes_per_second"] = .number(session.stats.kilobytesPerSecond)
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
