import Foundation

/// The words of an agent pill's card and menu (``HomeAgentPillCard``), localized in the Home catalog.
struct HomeAgentPillStrings {
    static var startNow: String { String(localized: "home.agentPill.startNow", defaultValue: "Start now", bundle: .l10n) }
    static var startNowHelp: String {
        String(localized: "home.agentPill.startNow.help", defaultValue: "Start this agent now, without waiting for a free slot", bundle: .l10n)
    }
    static var starting: String { String(localized: "home.agentPill.starting", defaultValue: "Starting…", bundle: .l10n) }
    static var startsNext: String { String(localized: "home.agentPill.queueNext", defaultValue: "Starts next", bundle: .l10n) }
    static func ahead(_ count: Int) -> String {
        String(format: String(localized: "home.agentPill.queueAhead", defaultValue: "%lld ahead of it", bundle: .l10n), count)
    }
    static var queued: String { String(localized: "home.agentPill.status.queued", defaultValue: "Queued", bundle: .l10n) }
    static var working: String { String(localized: "home.agentPill.status.working", defaultValue: "Working", bundle: .l10n) }
    static var reported: String { String(localized: "home.agentPill.status.reported", defaultValue: "Reported", bundle: .l10n) }
    static var stopped: String { String(localized: "home.agentPill.status.stopped", defaultValue: "Stopped without a report", bundle: .l10n) }
}
