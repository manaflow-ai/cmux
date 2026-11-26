internal import CCmuxLayoutReducerFFI
import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// The hidden browser tab rules, asked of Rust (cmux-tui/crates/cmux-tab-discard, with their tests)
/// over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `tab_discard_*`). The app reads
/// the facts (the setting, the pages, the probe) and performs the answer; the rules stay in Rust
/// (Leo: "swift to anything but swift").
enum TabDiscardRules {
    /// One JSON call of the app FFI; nil when it does not answer.
    static func call(_ operation: String, _ request: [String: Any]) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = data.withUnsafeBytes { bytes in
                operation.withCString { name in
                    output.withUnsafeMutableBytes { buffer in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, name,
                                                 buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity {
                capacity = length
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(output.prefix(length)))) as? [String: Any]
        }
        return nil
    }

    /// `setting` on the wire. The mode and `discards_automatically` always go explicitly: the
    /// crate's unset mode discards, the app's fallback does not.
    static func wire(_ setting: BrowserHibernationSetting) -> [String: Any] {
        var wire: [String: Any] = [
            "exclusions": setting.exclusions,
            "includes_pinned_tabs": setting.includesPinnedTabs,
            "discards_automatically": setting.discardsAutomatically,
            "freeze_seconds": setting.freezeSeconds.map { $0 as Any } ?? NSNull(),
        ]
        switch setting.mode {
        case .off: wire["mode"] = "off"
        case .moderate: wire["mode"] = "moderate"
        case .aggressive: wire["mode"] = "aggressive"
        case .minutes(let minutes): wire["mode"] = minutes
        }
        return wire
    }

    static func wire(_ candidate: HibernationPlanner.Candidate) -> [String: Any] {
        var wire: [String: Any] = [
            "key": candidate.key, "hidden_for": candidate.hiddenFor, "is_pinned": candidate.isPinned,
            "has_dev_tools": candidate.hasDevTools, "is_capturing": candidate.isCapturing, "can_restore": candidate.canRestore,
            "shows_form_submission": candidate.showsFormSubmission, "recent_focus_count": candidate.recentFocusCount,
            "is_downloading": candidate.isDownloading, "has_agent_lease": candidate.hasAgentLease,
            "recently_kept": candidate.recentlyKept, "allows_notifications": candidate.allowsNotifications,
        ]
        if let host = candidate.host { wire["host"] = host }
        if let bytes = candidate.memoryBytes { wire["memory_bytes"] = NSNumber(value: bytes) }
        return wire
    }

    static func wire(_ probe: PageProbe) -> [String: Any] {
        [
            "playing_media": probe.playingMedia, "media_session": probe.mediaSession, "edited_form": probe.editedForm,
            "capturing": probe.capturing, "web_audio": probe.webAudio, "before_unload": probe.beforeUnload,
            "unload_handler": probe.unloadHandler, "web_rtc": probe.webRTC, "connected_device": probe.connectedDevice,
            "unreadable_frame": probe.unreadableFrame, "answered": probe.answered,
        ]
    }

    static func wire(_ step: PageProbeHistory.Step) -> String {
        switch step {
        case .freeze: "freeze"
        case .discard: "discard"
        }
    }

    static func exemption(_ value: Any?) -> HibernationPlanner.Exemption? {
        (value as? String).flatMap(HibernationPlanner.Exemption.init(rawValue:))
    }

    /// A JSON number as seconds; nil for null.
    static func seconds(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }

    /// The reply's plan; an empty one (nothing due, no recheck) when the call failed.
    static func plan(_ operation: String, _ request: [String: Any]) -> HibernationPlanner.Plan {
        guard let reply = call(operation, request) else { return HibernationPlanner.Plan() }
        var plan = HibernationPlanner.Plan()
        plan.due = reply["due"] as? [String] ?? []
        plan.nextCheck = seconds(reply["next_check"])
        for (key, value) in reply["exemptions"] as? [String: Any] ?? [:] {
            // A reason this app does not know still keeps the page.
            plan.exemptions[key] = exemption(value) ?? .unsupported
        }
        return plan
    }
}
