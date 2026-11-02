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
    /// Cloud attention pushes navigate to the Cloud chat and never carry
    /// reply buttons. These categories still need registration so APNs does
    /// not silently fall back to an unknown category.
    case cloudQuestion = "CLOUD_QUESTION"
    case cloudPermission = "CLOUD_PERMISSION"
    case cloudDone = "CLOUD_DONE"
    /// The phone's own "Couldn't reach <Mac>" notification.
    case retry = "CMUX_MOBILE_RETRY"
    /// A sealed push before it opened, and any push that is not to be acted
    /// on (an unsealed one from a Mac that seals, a stale one): no buttons
    /// (PR B security review H1).
    case sealed = "CMUX_MOBILE_SEALED"
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

    /// Settings → Require Face ID (shared with the content extension through
    /// the App Group's defaults): Reply and Deny then open the app, so its
    /// lock stands in front of them too (PR #24156 review L2).
    public var requireFaceID: Bool

    public init(requireFaceID: Bool = false) {
        self.requireFaceID = requireFaceID
    }

    public static let requireFaceIDKey = "cmuxMobile.push.requireFaceID"

    /// With the choice saved in `defaults` (the App Group's suite, else standard).
    public init(defaults: UserDefaults?) {
        self.init(requireFaceID: defaults?.bool(forKey: Self.requireFaceIDKey) ?? false)
    }

    /// The app saves the choice for the extension (and re-registers its categories).
    public static func setRequireFaceID(_ on: Bool, defaults: UserDefaults?) {
        defaults?.set(on, forKey: requireFaceIDKey)
    }

    /// With the choice shared by the app (`PushSharedPreference`).
    public init(preference: PushSharedPreference) {
        self.init(requireFaceID: preference.requireFaceID)
    }

    /// The App Group's shared defaults.
    public static func sharedDefaults(_ group: PushAppGroup?) -> UserDefaults? {
        group.flatMap { UserDefaults(suiteName: $0.identifier) }
    }

    /// Whether `button` opens the app under these preferences.
    public func opensApp(_ button: PushAction) -> Bool {
        button.opensApp || (requireFaceID && (button == .deny || button == .reply || button == .terminalReply))
    }

    /// The buttons the content extension sets: the payload's own, or nil to
    /// keep the static buttons, as with Show previews off (their titles never
    /// name an option on the lock screen; PR #24156 review L1). With
    /// `replyField` the long look shows the system's reply field at its
    /// bottom (the category's Reply), so no "Reply" button stands beside it
    /// (the button opened a second field, and read as unexplained).
    public func extensionActions(for payload: PushPayload, replyField: Bool = false) -> [UNNotificationAction]? {
        guard payload.previews else { return nil }
                // Chief keeps its Reply button: its long look has no composer, and a
        // Chief alert without Reply read as unrepliable (2026-10-30).
        let plan = plan(for: payload).filter { !(replyField && $0.action == .reply && payload.kind != .chief) }
        return plan.map { button in
            // Without the composer the system field is the way to reply: say to whom.
            let title = button.action == .reply ? payload.agent.map { String(localized: "Reply to \($0)") } ?? button.title : button.title
            return action(button.action, title: title)
        }
    }

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
        case .terminal, .sealed, .cloudQuestion, .cloudPermission, .cloudDone: []
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
            // As the Feed (`PushPayload.phoneOptions`): Always allow only when the agent offers no
            // single-use Allow; acpmux then refuses it and says to allow it on the Mac.
            let options = payload.phoneOptions
            var out: [(action: PushAction, title: String)] = []
            if options.contains(where: { $0.kind == .allowOnce }) {
                out.append((.allowOnce, title(.allowOnce)))
            } else if options.contains(where: { $0.kind == .allowAlways }) {
                out.append((.allowAlways, title(.allowAlways)))
            }
            if options.contains(where: \.isReject) { out.append((.deny, title(.deny))) }
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
            let options: UNNotificationActionOptions = requireFaceID ? [.destructive, .authenticationRequired, .foreground] : [.destructive, .authenticationRequired]
            return UNNotificationAction(identifier: action.identifier, title: title, options: options)
        case .reply, .terminalReply:
            return UNTextInputNotificationAction(
                identifier: action.identifier, title: title, options: requireFaceID ? [.authenticationRequired, .foreground] : [.authenticationRequired],
                textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Reply")
            )
        }
    }
}

/// Settings → Require Face ID, shared with the content extension. The push
/// keychain group holds it in every build (the CI App Store profiles grant
/// the keychain group but no App Group); a build with the App Group also
/// keeps it in the group's defaults, which an older app wrote.
public struct PushSharedPreference {
    public static let requireFaceIDAccount = "preference.requireFaceID"

    public var keychain: (any PushSecretStore)?
    public var defaults: UserDefaults?

    public init(keychain: (any PushSecretStore)?, defaults: UserDefaults?) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// This build's: the push keychain group, and the App Group's defaults when it has one.
    public static func live(group: PushAppGroup?) -> PushSharedPreference {
        PushSharedPreference(keychain: PushKeychainStore.current(), defaults: PushActions.sharedDefaults(group))
    }

    public var requireFaceID: Bool {
        if let data = try? keychain?.read(Self.requireFaceIDAccount), let byte = data.first { return byte == 1 }
        return defaults?.bool(forKey: PushActions.requireFaceIDKey) ?? false
    }

    public func setRequireFaceID(_ on: Bool) {
        try? keychain?.write(Data([on ? 1 : 0]), account: Self.requireFaceIDAccount)
        defaults?.set(on, forKey: PushActions.requireFaceIDKey)
    }
}

/// Which stores a Require Face ID call writes. AppLock sends the setting on
/// appear, which may equal the stored value, and a needless
/// `UserDefaults.standard` write wakes `@AppStorage` readers. Only a change writes.
public struct PushFaceIDSync: Sendable, Equatable {
    /// The app's own defaults' value.
    public private(set) var local: Bool
    /// The value last written to the stores the extension reads; nil before the first write.
    public private(set) var shared: Bool?

    public struct Writes: Sendable, Equatable {
        public var local: Bool
        public var shared: Bool
    }

    public init(local: Bool) {
        self.local = local
    }

    public mutating func set(_ on: Bool) -> Writes {
        let writes = Writes(local: on != local, shared: on != shared)
        local = on
        shared = on
        return writes
    }
}
