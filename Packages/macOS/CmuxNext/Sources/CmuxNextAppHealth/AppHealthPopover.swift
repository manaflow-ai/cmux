public import AppKit
public import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// App health's card, opened by its triggers (the sidebar footer's line, ``AppHealthIndicatorView``, and the
/// "Restoring sessions…" card's Details): the one cmux dialog card on its glass, over the cmux window it was opened
/// from, native from its first frame (Lawrence 2026-11-17: "most dialogs should have 0 react involved"). The React
/// card it replaces drew nothing once the part was healthy again and never heard Escape, so its panel stayed up as
/// an empty glass shell. This card always has words (``AppHealthCard/spec(_:)``), follows the model while it
/// shows, and goes away on Done, Escape, or a click elsewhere.
@MainActor
public final class AppHealthPopover {
    private let health: AppHealth
    /// The card's panel while it shows (tests).
    private(set) var panel: CmuxFloatingDialogPanel?
    private var token: UInt64?

    public init(health: AppHealth) {
        self.health = health
    }

    /// A snapshot the card shows instead of the model's (DEBUG captures, ``AppHealthFeeds/debugMethod()``).
    var fixture: JSONValue?

    /// Opens the card over `window` (the person's click on a trigger), with the keyboard: Return repairs, Escape closes.
    public func open(over window: NSWindow?) {
        let panel = self.panel ?? CmuxFloatingDialogPanel(identifier: "cmux.appHealth")
        self.panel = panel
        panel.anchor = { [weak window] in window }
        panel.takesKeyboardOnShow = true
        panel.hidesWhenInactive = true
        panel.onHide = { [weak self] in self?.stopFollowing() }
        draw(fixture ?? health.snapshot)
        guard token == nil, fixture == nil else { return }
        // The model calls back on the thread that changed it, under its delivery lock: always queued to main, so the
        // card keeps the snapshots' order and never calls back into the model under its lock.
        token = health.subscribe { [weak self] snapshot in
            MainDelivery().later {
                guard let self, self.panel?.isVisible == true else { return }
                self.draw(snapshot)
            }
        }
    }

    /// Takes the card away (tests; the app closes it by Done, Escape or a click elsewhere).
    public func close() {
        panel?.hide()
    }

    private func draw(_ snapshot: JSONValue) {
        let spec = AppHealthCard.spec(snapshot)
        guard let panel, panel.dialogView?.spec != spec else { return }
        panel.show(spec) { [weak self] id in self?.pressed(id) }
    }

    private func pressed(_ id: String) {
        if id.hasPrefix(AppHealthCard.repairPrefix) {
            // The person's click or Return: the repair starts, and the card follows it (Repairing…, then all clear).
            health.repairNow(id: String(id.dropFirst(AppHealthCard.repairPrefix.count)))
            return
        }
        panel?.hide()
    }

    private func stopFollowing() {
        if let token { health.unsubscribe(token) }
        token = nil
    }
}

/// The card's words from a health snapshot (the shared health contract): the worst part's line as the title
/// ("Agent chat needs a repair"), what is wrong, the other parts, the actions waiting for a link, the last
/// repairs; Repair Now for a part the person may repair, and Done. A quiet snapshot reads "Everything is working",
/// never an empty card.
enum AppHealthCard {
    static let repairPrefix = "repair:"
    static let shownReceipts = 3

    static func spec(_ snapshot: JSONValue) -> CmuxDialogSpec {
        let headline = AppHealth.headline(of: snapshot)
        let parts = (snapshot["parts"]?.arrayValue ?? []).filter { state(of: $0) > .healthy }
        let worst = headline?.partID.flatMap { id in parts.first { $0["id"]?.stringValue == id } }
        var title = headline.flatMap(AppHealthStrings.line) ?? AppHealthStrings.allClear
        if headline == nil, let part = parts.first, let label = part["label"]?.stringValue, let words = AppHealthStrings.state(state(of: part)) {
            // Only a slow part: no footer line, but the card still names it.
            title = AppHealthStrings.partLine(label, words)
        }
        var lines: [String] = []
        if let detail = worst?["detail"]?.stringValue, !detail.isEmpty { lines.append(detail) }
        for part in parts where part["id"]?.stringValue != worst?["id"]?.stringValue {
            guard let label = part["label"]?.stringValue, let words = AppHealthStrings.state(state(of: part)) else { continue }
            lines.append(AppHealthStrings.partLine(label, words))
        }
        let pending = snapshot["pending"]?.arrayValue ?? []
        for item in pending.dropFirst(worst == nil ? 1 : 0) {
            if let label = item["label"]?.stringValue { lines.append(AppHealthStrings.pending(label)) }
        }
        if let more = snapshot["pendingMore"]?.intValue, more > 0 { lines.append(AppHealthStrings.pendingMore(more)) }
        let receipts = (snapshot["receipts"]?.arrayValue ?? []).prefix(shownReceipts).compactMap { receipt -> String? in
            guard let outcome = receipt["outcome"]?.stringValue.flatMap(AppHealthStrings.outcome),
                  let detail = receipt["detail"]?.stringValue else { return nil }
            return AppHealthStrings.partLine(outcome, detail)
        }
        if !receipts.isEmpty { lines.append(([AppHealthStrings.receipts] + receipts).joined(separator: "\n")) }
        var buttons = [CmuxDialogButton(id: "done", title: AppHealthStrings.done, role: .cancel)]
        if let worst, worst["canRepair"]?.boolValue == true, let id = worst["id"]?.stringValue {
            buttons.append(CmuxDialogButton(id: repairPrefix + id, title: AppHealthStrings.repairNow, role: .default))
        }
        return CmuxDialogSpec(title: title, lines: lines, buttons: buttons, identifier: "cmux.appHealth.card")
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A snapshot with Agent chat `state` (failed, repairing) after three reloads, or all clear (quiet): the card's
    /// captures (`debug.app_health_card`).
    static func fixture(state: String) -> JSONValue {
        let quiet = state == "quiet"
        let part: JSONValue = .object([
            "id": .string("page:7"), "kind": .string("page"), "label": .string("Agent chat"), "state": .string(state),
            "sinceMs": .number(0), "detail": .string("Agent chat stopped answering, and three reloads did not bring it back."),
            "action": .string("reloadPage"), "attempt": .number(3), "maxAttempts": .number(3), "nextAtMs": .null,
            "canRepair": .bool(state == "failed"),
        ])
        let receipt: JSONValue = .object([
            "atMs": .number(0), "id": .string("page:7"), "action": .string("reloadPage"),
            "outcome": .string("gaveUp"), "detail": .string("Reloaded Agent chat 3 times"),
        ])
        return .object([
            "worst": .string(quiet ? "healthy" : state), "parts": .array(quiet ? [] : [part]),
            "receipts": .array(quiet ? [] : [receipt]), "pending": .array([]), "pendingMore": .number(0),
        ])
    }
    #endif

    private static func state(of part: JSONValue) -> AppHealth.State {
        AppHealth.State(rawValue: part["state"]?.stringValue ?? "") ?? .healthy
    }
}

/// App health's native words: the part labels the app gives the Rust model, the footer line and the card's.
struct AppHealthStrings {
    static var allClear: String { String(localized: "appHealth.allClear", defaultValue: "Everything is working", table: "AppHealth", bundle: .module) }
    static var done: String { String(localized: "appHealth.done", defaultValue: "Done", table: "AppHealth", bundle: .module) }
    static var repairNow: String { String(localized: "appHealth.repairNow", defaultValue: "Repair now", table: "AppHealth", bundle: .module) }
    static var receipts: String { String(localized: "appHealth.receipts", defaultValue: "Recent repairs", table: "AppHealth", bundle: .module) }

    /// "Agent chat: Slow".
    static func partLine(_ label: String, _ state: String) -> String {
        String(format: String(localized: "appHealth.line", defaultValue: "%1$@: %2$@", table: "AppHealth", bundle: .module), label, state)
    }

    static func pending(_ label: String) -> String {
        String(format: String(localized: "appHealth.pending", defaultValue: "Reconnecting; will %@ when back", table: "AppHealth", bundle: .module), label)
    }

    static func pendingMore(_ count: Int) -> String {
        String(format: String(localized: "appHealth.pendingMore", defaultValue: "%@ more waiting", table: "AppHealth", bundle: .module), String(count))
    }

    static func outcome(_ outcome: String) -> String? {
        switch outcome {
        case "started": String(localized: "appHealth.outcome.started", defaultValue: "Repair started", table: "AppHealth", bundle: .module)
        case "ok": String(localized: "appHealth.outcome.ok", defaultValue: "Fixed", table: "AppHealth", bundle: .module)
        case "failed": String(localized: "appHealth.outcome.failed", defaultValue: "Failed", table: "AppHealth", bundle: .module)
        case "gaveUp": String(localized: "appHealth.outcome.gaveUp", defaultValue: "Gave up", table: "AppHealth", bundle: .module)
        default: nil
        }
    }

    static var sessionDaemon: String { String(localized: "appHealth.part.sessionDaemon", defaultValue: "Session service", table: "AppHealth", bundle: .module) }
    static var connection: String {
        String(localized: "appHealth.part.acpmux", defaultValue: "Connection to the session service", table: "AppHealth", bundle: .module)
    }
    static var pageHost: String { String(localized: "appHealth.part.pageHost", defaultValue: "Page server", table: "AppHealth", bundle: .module) }

    /// The page parts' names in plain words: a page's own name is its resource ("agent-pane"), which reads as
    /// code ("Agent pane"); the agent chat is what the person calls it.
    static func pageLabel(resource: String, fallback: String) -> String {
        switch resource {
        case "agent-pane":
            String(localized: "appHealth.part.agentChat", defaultValue: "Agent chat", table: "AppHealth", bundle: .module)
        default: fallback
        }
    }

    /// The footer line, as the web's indicator says it: what is wrong with which part, in a sentence the
    /// person can act on ("Agent chat isn't responding": the click opens Repair now; "Reloading Agent chat…":
    /// the app is on it), or with no unhealthy part the newest queued action ("Reconnecting; will close
    /// Background task when back"). A part that is only slow has no line (``AppHealth/headline(of:)``).
    static func line(_ headline: AppHealth.Headline) -> String? {
        if let label = headline.label, let state = headline.state {
            switch state {
            case .healthy, .slow: break
            case .stuck:
                return String(format: String(localized: "appHealth.line.stuck", defaultValue: "%@ isn’t responding", table: "AppHealth", bundle: .module), label)
            case .repairing:
                return String(format: String(localized: "appHealth.line.repairing", defaultValue: "Repairing %@…", table: "AppHealth", bundle: .module), label)
            case .failed:
                return String(format: String(localized: "appHealth.line.failed", defaultValue: "%@ needs a repair", table: "AppHealth", bundle: .module), label)
            }
        }
        return headline.pending.map {
            String(format: String(localized: "appHealth.pending", defaultValue: "Reconnecting; will %@ when back", table: "AppHealth", bundle: .module), $0)
        }
    }

    static func state(_ state: AppHealth.State) -> String? {
        switch state {
        case .healthy: nil
        case .slow: String(localized: "appHealth.state.slow", defaultValue: "Slow", table: "AppHealth", bundle: .module)
        case .repairing: String(localized: "appHealth.state.repairing", defaultValue: "Repairing", table: "AppHealth", bundle: .module)
        case .stuck: String(localized: "appHealth.state.stuck", defaultValue: "Not responding", table: "AppHealth", bundle: .module)
        case .failed: String(localized: "appHealth.state.failed", defaultValue: "Needs a repair", table: "AppHealth", bundle: .module)
        }
    }
}
