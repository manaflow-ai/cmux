import AppKit
import CmuxNextIcons
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

    static func icon(_ event: AgentActivityEvent) -> IconName {
        if !event.ok { return .statusError }
        switch event.kind {
        case .sessionStart: return .actionResume
        case .sessionEnd: return .statusSuccess
        case .sessionStop: return .actionStop
        case .sessionPause: return .actionPause
        case .sessionResume: return .actionResume
        case .sessionIdle: return .stateIdle
        case .observe: return .computeruseObserve
        case .policyReject: return .policyReject
        case .consentRequest, .consentDecide: return .permissionConsent
        case .error: return .statusWarning
        case .act:
            switch event.tool {
            case "type_text", "set_value": return .keyboard
            case "press_key", "hotkey": return .keyboardHotkey
            case "scroll": return .computeruseScroll
            case "drag": return .computeruseDrag
            default: return .computeruseClick
            }
        }
    }
}
