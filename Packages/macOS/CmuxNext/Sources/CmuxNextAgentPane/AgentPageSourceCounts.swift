public import CmuxNextSettings
public import Foundation

/// How an existing chat's page came to be, counted in every build (the Release NIGHTLY too; the DEBUG-only
/// ``AgentPaneSpareOutcome/trace(note:why:into:)`` is the bench's per-open account). Each tab that opens an existing
/// chat of this Mac makes one page: taken from the warm spare (`spareAdopted`), or built here: the kept page of a
/// Reopen Closed chat (`kept`), or a cold build (`cold`), with why the spare was not asked (``AgentPageColdReason``)
/// or why the spare refused (``AgentPaneSpareRefusalReason``). Constant memory: fixed counters, and two maps whose
/// keys come from closed enums (at most ``maxReasons``; a key past that counts as ``otherReason``).
///
/// The app keeps one in its ``AgentPageSources`` (``AgentPageRetirer/sources``); `agent.chat.perf` with `page_source` reads it.
public nonisolated struct AgentPageSourceCounts: Sendable, Equatable {
    /// Most keys each reason map keeps.
    public static let maxReasons = 12
    public static let otherReason = "other"

    public private(set) var spareAdopted = 0
    /// The pool had no spare parked for the open.
    public private(set) var spareEmpty = 0
    /// A spare was parked, but still connecting, in Low Power Mode or at serious thermal state.
    public private(set) var spareUnready = 0
    /// The spare was taken for the open and refused it (``coldWhy`` names nothing: see ``refusedWhy``).
    public private(set) var spareRefused = 0
    public private(set) var kept = 0
    public private(set) var cold = 0
    /// Cold builds by ``AgentPageColdReason/rawValue``.
    public private(set) var coldWhy: [String: Int] = [:]
    /// Refusals by ``AgentPaneSpareRefusalReason/key``.
    public private(set) var refusedWhy: [String: Int] = [:]

    public init() {}

    public mutating func record(_ source: AgentPageSource) {
        switch source {
        case .spareAdopted: spareAdopted += 1
        case .spareEmpty: spareEmpty += 1
        case .spareUnready: spareUnready += 1
        case .spareRefused(let reason):
            spareRefused += 1
            Self.bump(&refusedWhy, reason.key)
        case .kept: kept += 1
        case .cold(let reason):
            cold += 1
            Self.bump(&coldWhy, reason.rawValue)
        }
    }

    /// Counts `key` in `counts`, under ``otherReason`` once the map has ``maxReasons`` keys and `key` is new.
    static func bump(_ counts: inout [String: Int], _ key: String) {
        let key = counts[key] == nil && counts.count >= maxReasons ? otherReason : key
        counts[key, default: 0] += 1
    }

    public mutating func reset() {
        self = AgentPageSourceCounts()
    }

    /// The report `agent.chat.perf page_source` returns (its `page_source` object).
    public var json: JSONValue {
        func map(_ counts: [String: Int]) -> JSONValue {
            .object(counts.mapValues { .number(Double($0)) })
        }
        return .object([
            "spare_adopted": .number(Double(spareAdopted)),
            "spare_empty": .number(Double(spareEmpty)),
            "spare_unready": .number(Double(spareUnready)),
            "spare_refused": .number(Double(spareRefused)),
            "kept": .number(Double(kept)),
            "cold": .number(Double(cold)),
            "cold_why": map(coldWhy),
            "refused_why": map(refusedWhy),
        ])
    }
}

/// One chat-page make's outcome, for ``AgentPageSourceCounts/record(_:)``.
public nonisolated enum AgentPageSource: Sendable, Equatable {
    case spareAdopted, spareEmpty, spareUnready
    case spareRefused(AgentPaneSpareRefusalReason)
    case kept
    case cold(AgentPageColdReason)
}

/// Why an existing chat's open built its page cold instead of asking the spare (``AgentPaneSpareAdoption/coldReason(relaunchWake:chiefKeeps:)``).
/// ``spareNotTaken``: the open was eligible and the spare was not taken (its empty, unready or refused outcome is counted too).
public nonisolated enum AgentPageColdReason: String, Sendable, Equatable, CaseIterable {
    case notThisMac = "not_this_mac"
    case newTabPage = "new_tab_page"
    case seeded
    case wakeState = "wake_state"
    case relaunchWake = "relaunch_wake"
    case chiefKeeps = "chief_keeps"
    case spareNotTaken = "spare_not_taken"
}

/// Why a parked spare refused an existing chat (``AgentPaneModel/spareRefusalReason``). ``text`` is the trace note.
public nonisolated enum AgentPaneSpareRefusalReason: Sendable, Equatable {
    case hasSession
    case noNewTabPage
    case noHandshake
    case touched(by: String)
    case remoteChat
    case neverPooled
    case unknown

    public var key: String {
        switch self {
        case .hasSession: "has_session"
        case .noNewTabPage: "no_new_tab_page"
        case .noHandshake: "no_handshake"
        case .touched: "touched"
        case .remoteChat: "remote_chat"
        case .neverPooled: "never_pooled"
        case .unknown: "unknown"
        }
    }

    public var text: String {
        switch self {
        case .hasSession: "has a session"
        case .noNewTabPage: "no new tab page"
        case .noHandshake: "no handshake"
        case .touched(let by): "touched by \(by)"
        case .remoteChat: "remote chat"
        case .neverPooled: "never pooled"
        case .unknown: "?"
        }
    }
}

/// The app's one count of chat-page makes (``AgentPageSourceCounts``), on the main actor where the makes happen. The app's
/// ``AgentPageRetirer`` owns it (``AgentPageRetirer/sources``) and the recorders are handed it: the spare's outcome
/// (``AgentPaneSpareOutcome/trace(note:why:into:)``), the adoption decision
/// (``AgentPaneSpareAdoption/adoptedCounting(relaunchWake:chiefKeeps:into:)``), the retirer's kept page, and
/// ``AgentChatPerfControl``, which reads it.
@MainActor
public final class AgentPageSources {
    public private(set) var counts = AgentPageSourceCounts()

    public init() {}

    public func record(_ source: AgentPageSource) {
        counts.record(source)
    }

    /// `agent.chat.perf page_source`'s `page_source` object; `reset` zeroes the counts after the read.
    public func report(reset: Bool) -> JSONValue {
        let json = counts.json
        if reset { counts.reset() }
        return .object(["page_source": json])
    }
}
