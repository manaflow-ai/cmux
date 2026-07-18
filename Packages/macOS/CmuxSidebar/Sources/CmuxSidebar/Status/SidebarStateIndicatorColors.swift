internal import Foundation

/// An agent lifecycle state that a sidebar state-indicator color override
/// can target (`sidebar.stateIndicatorColors` in `cmux.json`).
///
/// Mirrors the displayable subset of the app's agent lifecycle states;
/// `unknown` has no case here because an unknown lifecycle never recolors
/// a status pill.
public enum SidebarStateIndicatorState: String, Sendable, Equatable, CaseIterable {
    /// The agent is actively working.
    case running
    /// The agent is blocked waiting on user input.
    case needsInput
    /// The agent is idle.
    case idle

    /// Returns the state that should drive a status pill's color when several
    /// panels report different lifecycle states for the same status key.
    ///
    /// Precedence is `needsInput` > `running` > `idle`: a blocked panel must
    /// stay visible even while a sibling panel under the same status key is
    /// still running — surfacing the blocked state is the whole point of the
    /// needs-input color. (This deliberately differs from the hibernation
    /// aggregation in `Workspace.agentHibernationLifecycleState`, which ranks
    /// `running` first because it answers "is anything still working?".)
    public func dominating(_ other: SidebarStateIndicatorState) -> SidebarStateIndicatorState {
        precedenceRank <= other.precedenceRank ? self : other
    }

    /// Sort rank backing `dominating(_:)`; lower ranks win.
    private var precedenceRank: Int {
        switch self {
        case .needsInput: 0
        case .running: 1
        case .idle: 2
        }
    }
}

/// User-configured per-state color overrides for the agent status pills shown
/// under sidebar workspace rows (`sidebar.stateIndicatorColors` in `cmux.json`).
///
/// Producers (Claude Code hooks, the CLI, the feed) report a hardcoded pill
/// color; when the user configures a color for a lifecycle state, that color
/// replaces the reported one for every status entry currently in that state.
/// A `nil` hex keeps the producer-reported color for that state.
public struct SidebarStateIndicatorColors: Equatable, Sendable {
    /// Hex color (`#RRGGBB`) for pills whose agent is running, or `nil` to
    /// keep the producer-reported color.
    public let runningHex: String?
    /// Hex color (`#RRGGBB`) for pills whose agent needs input, or `nil` to
    /// keep the producer-reported color.
    public let needsInputHex: String?
    /// Hex color (`#RRGGBB`) for pills whose agent is idle, or `nil` to keep
    /// the producer-reported color.
    public let idleHex: String?

    /// Creates a set of per-state color overrides.
    ///
    /// Empty or whitespace-only strings are normalized to `nil` so callers
    /// can pass raw `UserDefaults` values directly.
    public init(
        runningHex: String? = nil,
        needsInputHex: String? = nil,
        idleHex: String? = nil
    ) {
        self.runningHex = Self.normalized(runningHex)
        self.needsInputHex = Self.normalized(needsInputHex)
        self.idleHex = Self.normalized(idleHex)
    }

    /// Whether no state has a configured override.
    public var isEmpty: Bool {
        runningHex == nil && needsInputHex == nil && idleHex == nil
    }

    /// The configured hex color for a lifecycle state, or `nil` when unset.
    public func colorHex(for state: SidebarStateIndicatorState) -> String? {
        switch state {
        case .running: runningHex
        case .needsInput: needsInputHex
        case .idle: idleHex
        }
    }

    /// Resolves the override color for each status-entry key.
    ///
    /// - Parameter statesByKey: The aggregated lifecycle state per status key
    ///   (e.g. `"claude_code": .needsInput`).
    /// - Returns: A map of status key to configured hex color, containing only
    ///   keys whose current state has an override.
    public func overrideColorsByKey(
        statesByKey: [String: SidebarStateIndicatorState]
    ) -> [String: String] {
        guard !isEmpty else { return [:] }
        var colors: [String: String] = [:]
        for (key, state) in statesByKey {
            if let hex = colorHex(for: state) {
                colors[key] = hex
            }
        }
        return colors
    }

    /// Collapses empty or whitespace-only hex strings to `nil`.
    private static func normalized(_ hex: String?) -> String? {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
