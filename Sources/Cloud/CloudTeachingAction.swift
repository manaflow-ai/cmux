import Foundation

/// One row of the Cloud panel's "What can I do here?" popover: a top Cloud
/// action with its shortcut and the CLI command that does the same thing.
///
/// The CLI column uses the exact vocabulary `cmux vm --help` and the CLI's
/// "Next:" lines print, so the app and the terminal teach one set of words.
/// Rows that act on a machine name the real machine when one is known, so the
/// command can be copied and run as-is.
enum CloudTeachingAction: String, CaseIterable, Identifiable {
    case newMachine
    case openRepository
    case startAgent
    case openTerminal
    case secrets
    case syncSecrets
    case sharePort

    var id: String { rawValue }

    /// The three that take someone from nothing to work in progress come
    /// first; the divider sits before ``openTerminal``.
    static let primary: [CloudTeachingAction] = [.newMachine, .openRepository, .startAgent]
    static let secondary: [CloudTeachingAction] = [.openTerminal, .secrets, .syncSecrets, .sharePort]

    var title: String {
        switch self {
        case .newMachine:
            return String(localized: "cloudTeaching.action.newMachine", defaultValue: "New machine")
        case .openRepository:
            return String(localized: "cloudTeaching.action.openRepository", defaultValue: "Open a repository")
        case .startAgent:
            return String(localized: "cloudTeaching.action.startAgent", defaultValue: "Start an agent")
        case .openTerminal:
            return String(localized: "cloudTeaching.action.openTerminal", defaultValue: "Open a terminal")
        case .secrets:
            return String(localized: "cloudTeaching.action.secrets", defaultValue: "Cloud Secrets")
        case .syncSecrets:
            return String(localized: "cloudTeaching.action.syncSecrets", defaultValue: "Sync secrets")
        case .sharePort:
            return String(localized: "cloudTeaching.action.sharePort", defaultValue: "Share a port")
        }
    }

    var symbolName: String {
        switch self {
        case .newMachine: return "plus.square"
        case .openRepository: return "arrow.down.circle"
        case .startAgent: return "sparkles"
        case .openTerminal: return "terminal"
        case .secrets: return "key"
        case .syncSecrets: return "arrow.triangle.2.circlepath"
        case .sharePort: return "link"
        }
    }

    /// The configurable shortcut that runs the same action, when one exists.
    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .newMachine: return .newCloudMachine
        case .openRepository: return .openRepositoryInCloud
        case .openTerminal: return .newCloudWorkspace
        case .secrets: return .openCloudSecrets
        case .startAgent, .syncSecrets, .sharePort: return nil
        }
    }

    /// Whether the row needs a machine to act on.
    var needsMachine: Bool {
        switch self {
        case .openTerminal, .syncSecrets, .sharePort: return true
        case .newMachine, .openRepository, .startAgent, .secrets: return false
        }
    }

    /// The CLI command that does the same thing. `machine` is the label (or
    /// id) of the machine a machine row acts on; without one the command keeps
    /// the `<machine>` placeholder `cmux vm --help` uses.
    func cliCommand(machine: String?) -> String {
        let target = machine.map(Self.shellWord) ?? "<machine>"
        switch self {
        case .newMachine: return "cmux vm new"
        case .openRepository: return "cmux vm clone owner/repo"
        case .startAgent: return "cmux vm agent --agent claude -- \"<task>\""
        case .openTerminal: return "cmux vm open \(target)"
        case .secrets: return "cmux vm secrets ls"
        case .syncSecrets: return "cmux vm secrets sync \(target)"
        case .sharePort: return "cmux vm share \(target) <port> --team"
        }
    }

    /// Quotes a label that a shell would split or expand; machine ids and the
    /// usual `brave-otter` labels pass through untouched.
    static func shellWord(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/@"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
