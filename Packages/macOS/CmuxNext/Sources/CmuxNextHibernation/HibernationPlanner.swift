import CCmuxAppFFI
package import CmuxNextCompat
package import CmuxNextSettings
import Foundation

/// Which hidden pages are discarded or freeze now, and when to look again
/// (plans/cmux-next/tab-lifecycle.md). The rules live in Rust, with their tests
/// (cmux-tui/crates/cmux-tab-discard: the ranking, the pacing, the keep rules and the default), asked
/// over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `tab_discard_*`). Swift only
/// reports the facts (each hidden page's `Candidate`, its probe's answer) and `BrowserHibernation`
/// applies the result. Swift cannot hold the rules: they are product rules, and a product rule lives
/// once, in Rust (cmux CLAUDE.md, "New logic in Rust").
package struct HibernationPlanner {
    package init() {}
    /// One hidden page that could hibernate: the facts the rules read.
    package struct Candidate: Hashable, Encodable {
        package var key: String
        /// Seconds since the page was last visible.
        package var hiddenFor: Double
        package var host: String?
        package var isPinned = false
        package var hasDevTools = false
        /// Camera or microphone in use (Page Info); the probe finds the rest (`PageProbe.capturing`).
        package var isCapturing = false
        /// The engine can save and restore its history.
        package var canRestore = true
        package var showsFormSubmission = false  // the shown document came from a POST (BR-R1)
        /// Times the person showed the tab in the last hour (`BrowserHibernation.focusWindow`).
        package var recentFocusCount = 0
        /// The page's memory (its renderers' footprint, shared ones split), when sampled.
        package var memoryBytes: UInt64?
        /// A download the page started still runs.
        package var isDownloading = false
        /// An agent holds the page's browser lease (its cursor is on it).
        package var hasAgentLease = false
        /// The probe kept the page lately (it played or held form input).
        package var recentlyKept = false
        /// The page's site may show notifications (its permission is Allow).
        package var allowsNotifications = false

        package init(key: String, hiddenFor: Double, host: String? = nil, isPinned: Bool = false, hasDevTools: Bool = false,
                     isCapturing: Bool = false, canRestore: Bool = true, showsFormSubmission: Bool = false,
                     recentFocusCount: Int = 0, memoryBytes: UInt64? = nil, isDownloading: Bool = false,
                     hasAgentLease: Bool = false, recentlyKept: Bool = false, allowsNotifications: Bool = false) {
            self.key = key
            self.hiddenFor = hiddenFor
            self.host = host
            self.isPinned = isPinned
            self.hasDevTools = hasDevTools
            self.isCapturing = isCapturing
            self.canRestore = canRestore
            self.showsFormSubmission = showsFormSubmission
            self.recentFocusCount = recentFocusCount
            self.memoryBytes = memoryBytes
            self.isDownloading = isDownloading
            self.hasAgentLease = hasAgentLease
            self.recentlyKept = recentlyKept
            self.allowsNotifications = allowsNotifications
        }

        enum CodingKeys: String, CodingKey {
            case key, host
            case hiddenFor = "hidden_for", isPinned = "is_pinned", hasDevTools = "has_dev_tools", isCapturing = "is_capturing"
            case canRestore = "can_restore", showsFormSubmission = "shows_form_submission"
            case recentFocusCount = "recent_focus_count", memoryBytes = "memory_bytes", isDownloading = "is_downloading"
            case hasAgentLease = "has_agent_lease", recentlyKept = "recently_kept", allowsNotifications = "allows_notifications"
        }
    }

    /// Why a page does not hibernate (reported by `debug.surfaces`). The rules answer the ones they
    /// decide; the app adds its own (`neighbor`, `agentDriving`, `agentBusy`, ...).
    package enum Exemption: String, Hashable, Decodable {
        case disabled, excluded, pinned, devTools = "devtools", capturing, unsupported
        /// Found by the probe right before hibernating.
        case audio, formInput = "form_input"
        /// A running Web Audio context, at every memory pressure.
        case webAudio = "web_audio"
        /// The page would ask before it unloads.
        case beforeUnload = "before_unload"
        /// A connected WebRTC peer connection.
        case webRTC = "web_rtc"
        /// An open USB, HID or serial device, or a connected Bluetooth GATT server.
        case connectedDevice = "connected_device"
        /// The person moved into a child frame whose fields cannot be read.
        case unreadableFrame = "unreadable_frame"
        /// The page's site may show notifications; kept from the timeout, not from memory pressure.
        case notifications
        /// An agent chat whose agent works or waits on the person (AgentPageHibernation).
        case agentBusy = "agent_busy"
        /// The acpmux turn watch is down, so no chat's turn is known: every chat counts as busy.
        case agentTurnsUnknown = "agent_turns_unknown"
        case formSubmission = "form_submission"  // the page shows a form result (BR-R1)
        /// An agent called the page within `BrowserHibernation.agentGrace`.
        case agentDriving = "agent_driving"
        /// Beside a pane's shown tab, or hovered (`browser.keepNeighborTabsAwake`).
        case neighbor
        /// The page did not answer the probe and still gets the benefit of the doubt.
        case unanswered
        /// A download the page started still runs.
        case downloading
        /// An agent holds the page's browser lease.
        case agentLease = "agent_lease"
        /// A chat page held awake by its own rule (HiddenChatPages).
        case keepsState = "keeps_state"
    }

    package struct Plan: Equatable, Decodable {
        /// Keys to hibernate now (after the probe), or to freeze.
        package var due: [String] = []
        /// Seconds until the next page reaches its deadline; nil when none will.
        package var nextCheck: Double?
        package var exemptions: [String: Exemption] = [:]

        package init(due: [String] = [], nextCheck: Double? = nil, exemptions: [String: Exemption] = [:]) {
            self.due = due
            self.nextCheck = nextCheck
            self.exemptions = exemptions
        }

        enum CodingKeys: String, CodingKey { case due, nextCheck = "next_check", exemptions }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            due = try container.decode([String].self, forKey: .due)
            nextCheck = try container.decodeIfPresent(Double.self, forKey: .nextCheck)
            // A reason this build does not know is dropped, not the whole plan.
            let raw = try container.decodeIfPresent([String: String].self, forKey: .exemptions) ?? [:]
            exemptions = raw.compactMapValues(Exemption.init(rawValue:))
        }
    }

    /// Seconds hidden before a page hibernates; nil means never (or the rules did not answer).
    package static func threshold(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel) -> Double? {
        struct Reply: Decodable { var seconds: Double? }
        return TabDiscardRules.call("tab_discard_threshold", Request(setting: setting, pressure: pressure), as: Reply.self)?.seconds
    }

    /// Why `candidate` never hibernates by the timeout or pressure, before its page is asked. A rules
    /// call that does not answer keeps the page (`unsupported`): nothing is discarded unasked.
    package static func exemption(_ candidate: Candidate, setting: BrowserHibernationSetting) -> Exemption? {
        struct Reply: Decodable { var exemption: Exemption? }
        let request = Request(setting: setting, candidate: candidate)
        guard let reply = TabDiscardRules.call("tab_discard_exemption", request, as: Reply.self) else { return .unsupported }
        return reply.exemption
    }

    /// Which hidden pages freeze now, and when the next one will (`tab_discard_freeze_plan`).
    package static func freezePlan(_ setting: BrowserHibernationSetting, candidates: [Candidate]) -> Plan {
        TabDiscardRules.call("tab_discard_freeze_plan", Request(setting: setting, candidates: candidates), as: Plan.self) ?? Plan()
    }

    /// The pages to hibernate now, least valuable first, and when to look again (`tab_discard_plan`).
    /// A rules call that does not answer discards nothing.
    package static func plan(_ setting: BrowserHibernationSetting, pressure: MemoryPressureLevel, candidates: [Candidate]) -> Plan {
        let request = Request(setting: setting, pressure: pressure, candidates: candidates)
        return TabDiscardRules.call("tab_discard_plan", request, as: Plan.self) ?? Plan()
    }

    /// One request of the rules: the setting's values, and what the op reads.
    private struct Request: Encodable {
        var setting: BrowserHibernationSetting.Wire
        var pressure: MemoryPressureLevel?
        var candidates: [Candidate]?
        var candidate: Candidate?

        init(setting: BrowserHibernationSetting, pressure: MemoryPressureLevel? = nil, candidates: [Candidate]? = nil,
             candidate: Candidate? = nil) {
            self.setting = setting.wire
            self.pressure = pressure
            self.candidates = candidates
            self.candidate = candidate
        }
    }
}

extension BrowserHibernationSetting {
    /// The values the rules read (cmux-tab-discard `Setting`).
    struct Wire: Encodable {
        var mode: JSONValue
        var exclusions: [String]
        var includesPinnedTabs: Bool
        var freezeSeconds: Double?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mode, forKey: .mode)
            try container.encode(exclusions, forKey: .exclusions)
            try container.encode(includesPinnedTabs, forKey: .includesPinnedTabs)
            // Null, not absent: an absent value is the rules' default (30 s), "off" is null.
            try container.encode(freezeSeconds, forKey: .freezeSeconds)
        }

        enum CodingKeys: String, CodingKey { case mode, exclusions, includesPinnedTabs = "includes_pinned_tabs", freezeSeconds = "freeze_seconds" }
    }

    var wire: Wire { Wire(mode: configValue, exclusions: exclusions, includesPinnedTabs: includesPinnedTabs, freezeSeconds: freezeSeconds) }
}

/// The app FFI's JSON channel for the tab discard rules (`tab_discard_*`). Every type it sends or reads names its snake_case keys itself: a key strategy would rewrite the page keys of `Plan.exemptions` too.
package struct TabDiscardRules {
    package init() {}

    /// One JSON call; nil when the rules do not answer.
    package static func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(request), let reply = callData(operation, data) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Reply.self, from: reply)
    }

    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = max(4096, data.count * 2)
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { request in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &outputLength)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return Data(output.prefix(outputLength))
        }
        return nil
    }
}
