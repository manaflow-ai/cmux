#if DEBUG && os(iOS)
import CmuxMobileFeed
import CmuxMobileModel
import Foundation

/// DEBUG only: Agent Alarms' paths that need a live Mac, driven in a simulator for evidence.
/// Release, TestFlight and App Store builds compile none of it.
///
/// - `CMUX_MOBILE_DEV_AGENT_ALARM_FEED=permission|question|needsInput|failed`: a few seconds
///   after launch, a new event of that kind arrives in the Feed, as a Mac's live link delivers
///   one; `AgentAlarmFeedWatch` rings for it like any other.
/// - `CMUX_MOBILE_DEV_AGENT_ALARM_CLOSE=SECONDS`: that ask is then answered after SECONDS, so
///   its alarm stops by itself.
/// - `CMUX_MOBILE_DEV_AGENT_ALARM_MAC_OFFLINE=NAME`: a Mac named NAME links, then drops, and
///   `AgentAlarmMacWatch` rings after its grace (3 s here instead of 60 s).
@MainActor
enum AgentAlarmDebug {
    static func runIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let kind = environment["CMUX_MOBILE_DEV_AGENT_ALARM_FEED"] {
            let close = environment["CMUX_MOBILE_DEV_AGENT_ALARM_CLOSE"].flatMap(Double.init)
            Task { await arrive(kind, closeAfter: close) }
        }
        if let name = environment["CMUX_MOBILE_DEV_AGENT_ALARM_MAC_OFFLINE"] {
            Task { await dropMac(named: name) }
        }
    }

    private static func arrive(_ kind: String, closeAfter: Double?) async {
        try? await Task.sleep(for: .seconds(4))
        let now = Date()
        let mock = FeedStore.mockItems(now: now)
        func sample(_ id: String) -> FeedItem? { mock.first { $0.id == id } }
        var item: FeedItem
        switch kind {
        case "permission": guard let found = sample("f-permission") else { return }; item = found
        case "question": guard let found = sample("f-question") else { return }; item = found
        case "failed": guard let found = sample("f-failed") else { return }; item = found
        case "needsInput":
            guard let found = sample("f-failed") else { return }
            item = found
            item.kind = .needsInput
            item.opensTerminal = true
            item.agentName = "Claude Code"
            item.markdown = "Claude Code is waiting in its terminal: **Do you want to make this edit to Package.swift?**"
        default: return
        }
        let suffix = String(UUID().uuidString.prefix(8))
        item.id = item.needsYou ? "ask-dev-\(suffix)" : "dev-\(kind)-\(suffix)"
        item.createdAt = now
        item.isRead = false
        FeedStore.shared.upsert(item, atTop: true)
        guard let closeAfter, item.needsYou else { return }
        try? await Task.sleep(for: .seconds(closeAfter))
        item.resolution = "Allowed on the Mac"
        FeedStore.shared.upsert(item, atTop: true)
    }

    private static func dropMac(named name: String) async {
        try? await Task.sleep(for: .seconds(4))
        let watch = AgentAlarmMacWatch.shared
        watch.grace = .seconds(3)
        let mac = "dev-mac-\(name)"
        watch.update([mac: .connected], names: [mac: name], active: true)
        try? await Task.sleep(for: .seconds(1))
        watch.update([mac: .failed("unreachable")], names: [mac: name], active: true)
    }
}
#endif
