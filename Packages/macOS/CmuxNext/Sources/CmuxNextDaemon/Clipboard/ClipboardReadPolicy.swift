import Foundation

/// The user's Ghostty `clipboard-read` key: `allow`, `deny` or `ask`.
public enum ClipboardReadSetting: String, Sendable, Hashable {
    case allow, deny, ask

    /// The setting for the raw value the Ghostty config returns. A missing
    /// or unknown value is Ghostty's default, `ask`.
    public init(ghosttyValue: String?) {
        self = ghosttyValue.flatMap(Self.init(rawValue:)) ?? .ask
    }
}

/// What the app does with one clipboard read.
public enum ClipboardReadDecision: Sendable, Hashable {
    /// Answer with the pasteboard text at once.
    case allow
    /// Refuse at once.
    case deny
    /// Ask the user, naming the terminal and its host.
    case ask
}

/// Decision CLIPBOARD-READ-BROKER: Ghostty's `allow` applies to terminals on
/// this Mac only; a remote or Cloud terminal is always asked about, so this
/// Mac's clipboard never leaves it without the user's answer. `deny` refuses
/// everywhere.
public enum ClipboardReadPolicy {
    public static func decide(_ setting: ClipboardReadSetting, host: ClipboardReadHostKind) -> ClipboardReadDecision {
        switch setting {
        case .deny: .deny
        case .ask: .ask
        case .allow: host == .local ? .allow : .ask
        }
    }
}
