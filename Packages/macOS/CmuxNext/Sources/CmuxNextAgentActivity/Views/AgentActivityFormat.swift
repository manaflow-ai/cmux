import AppKit
import SwiftUI

enum AgentActivityFormat {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func symbol(_ event: AgentActivityEvent) -> String {
        if !event.ok { return "exclamationmark.triangle.fill" }
        switch event.kind {
        case .sessionStart: return "play.circle"
        case .sessionEnd: return "checkmark.circle"
        case .sessionStop: return "stop.circle"
        case .sessionPause: return "pause.circle"
        case .sessionResume: return "play.circle"
        case .sessionIdle: return "moon"
        case .observe: return "eye"
        case .policyReject: return "hand.raised"
        case .consentRequest, .consentDecide: return "person.badge.shield.checkmark"
        case .error: return "exclamationmark.triangle"
        case .act:
            switch event.tool {
            case "type_text", "set_value": return "keyboard"
            case "press_key", "hotkey": return "command"
            case "scroll": return "scroll"
            case "drag": return "hand.draw"
            default: return "cursorarrow.click"
            }
        }
    }
}
