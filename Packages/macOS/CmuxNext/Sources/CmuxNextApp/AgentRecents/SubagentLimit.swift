import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// Subagent Limit… on a chat (Leo: "Right-click, edit subagent count"): how many of a chat's
/// sub-sessions acpmux runs at once (`_acpmux/subsession/limits` `maxRunning`). A chat's own value
/// comes first, then its workspace's, then `agents.subsessions.maxRunning`. There is no workspace
/// item yet: acpmux reads a workspace's value through a chat's `workspace_id`, which chats started
/// in the app do not carry.
/// The dialog reads the current value, asks for a number or Use Default, and sends it; a number
/// sets the value, `null` clears it. Running sub-sessions never stop when it goes down.
@MainActor
struct SubagentLimit {
    static let method = "_acpmux/subsession/limits"

    /// What the limit belongs to.
    enum Scope: Equatable {
        /// One chat, by its acpmux session id.
        case chat(String)

        /// The request's params: `maxRunning` left out reads, a number sets, `nil` clears.
        func params(_ change: Change?) -> [String: Any] {
            var params: [String: Any] = switch self {
            case .chat(let session): ["sessionId": session]
            }
            switch change {
            case nil: break
            case .set(let value): params["maxRunning"] = value
            case .useDefault: params["maxRunning"] = NSNull()
            }
            return params
        }
    }

    /// What the person chose in the dialog.
    enum Change: Equatable {
        case set(Int)
        case useDefault
    }

    /// The limit as acpmux reports it.
    struct Current: Equatable {
        /// The scope's own value; nil when it uses the next one down.
        var own: Int?
        /// The value in effect.
        var effective: Int?
        /// The chat's sub-sessions running a turn now, and the ones waiting for a slot.
        var running: Int?
        var queued: Int?

        /// The current value from a read's reply; nil when acpmux has no run limit (an acpmux
        /// from before `maxRunning` answers a chat's read without it).
        init?(reply: [String: Any], scope: Scope) {
            switch scope {
            case .chat:
                guard let limits = reply["subsessionLimits"] as? [String: Any],
                      let effective = Self.int(limits["maxRunning"]) else { return nil }
                self.effective = effective
                own = limits["maxRunningSource"] as? String == "session" ? effective : nil
                running = Self.int(limits["running"])
                queued = Self.int(limits["queued"])
            }
        }

        init(own: Int? = nil, effective: Int? = nil, running: Int? = nil, queued: Int? = nil) {
            self.own = own
            self.effective = effective
            self.running = running
            self.queued = queued
        }

        private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    }

    /// The field's id in the dialog's answer.
    static let field = "maxRunning"
    static let setButton = "set"
    static let defaultButton = "useDefault"

    /// The numbers the field takes (the settings row's range).
    static var range: ClosedRange<Int> {
        let range = SubsessionSettings.subsessionsMaxRunningRange
        return Int(range.lowerBound)...Int(range.upperBound)
    }

    let scope: Scope
    let current: Current
    /// The global setting: the field's placeholder when acpmux sent no value in effect.
    let setting: Int

    /// The dialog: what the limit does, a chat's running and waiting counts, the field
    /// (the own value, else empty with the value in effect as its placeholder) and Cancel,
    /// Use Default and Set.
    var spec: CmuxDialogSpec {
        var lines = [SubagentLimitStrings.chatLine]
        if let running = current.running, let queued = current.queued {
            lines.append(SubagentLimitStrings.status(running: running, queued: queued))
        }
        let placeholder = String(current.effective ?? setting)
        return CmuxDialogSpec(
            title: SubagentLimitStrings.title, lines: lines,
            fields: [.text(Self.field, initial: current.own.map(String.init) ?? "", label: SubagentLimitStrings.field,
                           placeholder: placeholder)],
            buttons: [.cancel(), CmuxDialogButton(id: Self.defaultButton, title: SubagentLimitStrings.useDefault),
                      CmuxDialogButton(id: Self.setButton, title: SubagentLimitStrings.set, role: .default)],
            identifier: "cmux.dialog.subagentLimit")
    }

    /// The change for `answer`: nil when the person cancelled, `.failure` for a field that is not a
    /// whole number in ``range``. Set with an empty field uses the default, as Use Default does.
    static func change(for answer: CmuxDialogAnswer) -> Result<Change, InvalidNumber>? {
        if answer.isDismissal || answer.isCancel { return nil }
        if answer.button == defaultButton { return .success(.useDefault) }
        guard answer.button == setButton else { return nil }
        let text = (answer.text(field) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .success(.useDefault) }
        guard let value = Int(text), range.contains(value) else { return .failure(InvalidNumber()) }
        return .success(.set(value))
    }

    /// A field that is not a number the limit takes.
    struct InvalidNumber: Error, Equatable {}
}

/// Handlers.xcstrings.
enum SubagentLimitStrings {
    static var title: String {
        String(localized: "subagentLimit.title", defaultValue: "Subagent Limit", table: "Handlers", bundle: .module)
    }
    static var chatLine: String {
        String(localized: "subagentLimit.chat.line",
               defaultValue: "The most subagents this chat runs at the same time. More wait their turn and start as running ones finish.",
               table: "Handlers", bundle: .module)
    }
    static func status(running: Int, queued: Int) -> String {
        String(format: String(localized: "subagentLimit.status", defaultValue: "%1$lld running, %2$lld waiting.",
                              table: "Handlers", bundle: .module), running, queued)
    }
    static var field: String {
        String(localized: "subagentLimit.field", defaultValue: "Subagents at once", table: "Handlers", bundle: .module)
    }
    static var useDefault: String {
        String(localized: "subagentLimit.useDefault", defaultValue: "Use Default", table: "Handlers", bundle: .module)
    }
    static var set: String {
        String(localized: "subagentLimit.set", defaultValue: "Set", table: "Handlers", bundle: .module)
    }
    static var invalid: String {
        let range = SubagentLimit.range
        return String(format: String(localized: "subagentLimit.invalid", defaultValue: "Enter a whole number from %1$lld to %2$lld.",
                                     table: "Handlers", bundle: .module), range.lowerBound, range.upperBound)
    }
    static var failed: String {
        String(localized: "subagentLimit.failed", defaultValue: "The subagent limit could not be changed.",
               table: "Handlers", bundle: .module)
    }
    /// No acpmux answered the read, it did not take the person proof, or it refused the read.
    static var unreadable: String {
        String(localized: "subagentLimit.unreadable", defaultValue: "The subagent limit could not be read.",
               table: "Handlers", bundle: .module)
    }
    static var unsupported: String {
        String(localized: "subagentLimit.unsupported",
               defaultValue: "This version of acpmux has no subagent limit. Update cmux to set one.",
               table: "Handlers", bundle: .module)
    }
    static var notAChat: String {
        String(localized: "subagentLimit.notAChat", defaultValue: "Only an agent chat on this Mac has a subagent limit.",
               table: "Handlers", bundle: .module)
    }
}
