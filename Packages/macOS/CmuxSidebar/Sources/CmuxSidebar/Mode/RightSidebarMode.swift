import Foundation

/// The content pane shown in the right sidebar (the panel toggled by ⌘⌥B).
///
/// This is the pure, `Sendable` data core of the right-sidebar mode. Its raw
/// `String` values are the wire/Defaults representation and must stay stable.
/// App-coupled affordances (localized label, SF Symbol, keyboard-shortcut
/// action, `NSEvent` shortcut matching, and `UserDefaults`-backed availability)
/// live in app-target extensions on this type; only logic that needs no AppKit,
/// localization, or live settings is defined here.
public enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case find
    case sessions
    case feed
    case dock
    /// Transient custom-sidebar mode (main-merge feature). Consumers normalize it
    /// to `.files`; it is not independently selectable.
    case customSidebar
}

extension RightSidebarMode {
    /// Resolve a mode from a CLI argument, accepting the `vault` alias for
    /// `sessions`. Returns `nil` for an unrecognized argument. Case- and
    /// whitespace-insensitive.
    public static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        default:
            return nil
        }
    }

    /// Whether this mode is available given the two beta-feature gates. `files`,
    /// `find`, and `sessions` are always available; `feed` and `dock` are gated.
    public func isAvailable(feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sessions:
            return true
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        case .customSidebar:
            return false
        }
    }

    /// The modes available given the two beta-feature gates, in declaration order.
    public static func availableModes(feedEnabled: Bool, dockEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter { $0.isAvailable(feedEnabled: feedEnabled, dockEnabled: dockEnabled) }
    }
}
