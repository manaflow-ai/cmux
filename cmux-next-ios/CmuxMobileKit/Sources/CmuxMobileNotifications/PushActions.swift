import Foundation
import UserNotifications

/// The notification categories (PROTOCOL.md "Push notifications", `category`).
public enum PushCategory: String, CaseIterable, Sendable {
    case question = "CMUX_MOBILE_QUESTION"
    case questionForm = "CMUX_MOBILE_QUESTION_FORM"
    case permission = "CMUX_MOBILE_PERMISSION"
    case completed = "CMUX_MOBILE_COMPLETED"
    case failed = "CMUX_MOBILE_FAILED"
    case chief = "CMUX_MOBILE_CHIEF"
    case terminal = "CMUX_MOBILE_TERMINAL"
    /// The phone's own "Couldn't reach <Mac>" notification.
    case retry = "CMUX_MOBILE_RETRY"
}

/// One notification button (PROTOCOL.md "Phone actions").
public enum PushAction: Equatable, Hashable, Sendable {
    /// A single-choice question's option, by index in its first question.
    case option(Int)
    /// "Answer…": opens the app on the question.
    case answer
    case allowOnce
    case allowAlways
    case deny
    /// Text reply to a finished turn, an error or a Chief message.
    case reply
    /// Text into a terminal (PR B).
    case terminalReply
    case retry

    public static let optionPrefix = "cmux.option."

    public init?(identifier: String) {
        switch identifier {
        case "cmux.answer": self = .answer
        case "cmux.allow.once": self = .allowOnce
        case "cmux.allow.always": self = .allowAlways
        case "cmux.deny": self = .deny
        case "cmux.reply": self = .reply
        case "cmux.terminal.reply": self = .terminalReply
        case "cmux.retry": self = .retry
        default:
            guard identifier.hasPrefix(Self.optionPrefix), let index = Int(identifier.dropFirst(Self.optionPrefix.count)), index >= 0 else {
                return nil
            }
            self = .option(index)
        }
    }

    public var identifier: String {
        switch self {
        case .option(let index): "\(Self.optionPrefix)\(index)"
        case .answer: "cmux.answer"
        case .allowOnce: "cmux.allow.once"
        case .allowAlways: "cmux.allow.always"
        case .deny: "cmux.deny"
        case .reply: "cmux.reply"
        case .terminalReply: "cmux.terminal.reply"
        case .retry: "cmux.retry"
        }
    }

    /// Opens the app: an Allow and an answer are signed after Face ID, which
    /// iOS shows only in a foreground app (verify/rich-push.md).
    public var opensApp: Bool {
        switch self {
        case .option, .answer, .allowOnce, .allowAlways, .retry: true
        case .deny, .reply, .terminalReply: false
        }
    }
}

/// Builds the categories to register and each notification's own buttons.
public struct PushActions: Sendable {
    /// Single-choice options shown as buttons; more become "Answer…".
    public static let maxOptionButtons = 4

    public init() {}

    /// Every category, with the buttons a notification gets without the
    /// content extension (which replaces them with the payload's own).
    public var categories: Set<UNNotificationCategory> {
        Set(PushCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: staticActions(category),
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: String(localized: "Notification from your Mac"),
                options: []
            )
        })
    }

    func staticActions(_ category: PushCategory) -> [UNNotificationAction] {
        switch category {
        case .question, .questionForm: [action(.answer)]
        case .permission: [action(.allowOnce), action(.deny)]
        case .completed, .failed, .chief: [action(.reply)]
        case .terminal: []
        case .retry: [action(.retry)]
        }
    }

    /// The payload's own buttons (the content extension sets them).
    public func actions(for payload: PushPayload) -> [UNNotificationAction] {
        plan(for: payload).map { action($0.action, title: $0.title) }
    }

    /// The buttons as data: what `actions(for:)` builds.
    public func plan(for payload: PushPayload) -> [(action: PushAction, title: String)] {
        switch payload.kind {
        case .question:
            guard payload.isSingleChoice, let question = payload.questions.first else { return [(.answer, title(.answer))] }
            var out = question.options.enumerated().map { (PushAction.option($0.offset), $0.element.label) }
            if question.allowsOther { out.append((.answer, title(.answer))) }
            return out
        case .permission:
            // None listed (a v1 push, or a sealed one the Mac trimmed to fit): the app opens on it.
            guard !payload.options.isEmpty else { return [(.answer, title(.answer))] }
            var out: [(action: PushAction, title: String)] = []
            if payload.options.contains(where: { $0.kind == .allowOnce }) { out.append((.allowOnce, title(.allowOnce))) }
            if payload.options.contains(where: { $0.kind == .allowAlways }) { out.append((.allowAlways, title(.allowAlways))) }
            if payload.options.contains(where: \.isReject) { out.append((.deny, title(.deny))) }
            return out
        case .completed, .failed, .chief:
            return [(.reply, title(.reply))]
        case .terminal:
            // Text into the terminal (device unlock), only when its poster takes a reply.
            return payload.replyable && payload.notificationId != nil ? [(.terminalReply, title(.terminalReply))] : []
        }
    }

    func title(_ action: PushAction) -> String {
        switch action {
        case .option(let index): String(localized: "Option \(index + 1)")
        case .answer: String(localized: "Answer…")
        case .allowOnce: String(localized: "Allow once")
        case .allowAlways: String(localized: "Always allow")
        case .deny: String(localized: "Deny")
        case .reply, .terminalReply: String(localized: "Reply")
        case .retry: String(localized: "Retry")
        }
    }

    func action(_ action: PushAction, title: String? = nil) -> UNNotificationAction {
        let title = title ?? self.title(action)
        switch action {
        case .option, .allowOnce, .allowAlways:
            return UNNotificationAction(identifier: action.identifier, title: title, options: [.foreground, .authenticationRequired])
        case .answer, .retry:
            return UNNotificationAction(identifier: action.identifier, title: title, options: [.foreground])
        case .deny:
            return UNNotificationAction(identifier: action.identifier, title: title, options: [.destructive, .authenticationRequired])
        case .reply, .terminalReply:
            return UNTextInputNotificationAction(
                identifier: action.identifier, title: title, options: [.authenticationRequired],
                textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Reply")
            )
        }
    }
}
