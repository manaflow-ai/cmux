// Sources/Island/IslandSession.swift

import AppKit
import Foundation

/// Known AI-agent kinds the cmux Island monitors.
///
/// A terminal panel counts as an active island session iff its
/// `Workspace.statusEntries` contains at least one entry whose key equals
/// one of these raw values. Agent hooks in `docs/notifications.md` already
/// use these keys.
enum IslandAgentKind: String, CaseIterable, Hashable, Sendable {
    case claudeCode = "claude_code"
    case codex      = "codex"
    case copilotCli = "copilot_cli"
    case openCode   = "opencode"
    case geminiCli  = "gemini_cli"
    case cursor     = "cursor"
    case amp        = "amp"
    case droid      = "droid"

    /// Human-readable name shown in the expanded island row.
    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .copilotCli: return "Copilot CLI"
        case .openCode:   return "OpenCode"
        case .geminiCli:  return "Gemini CLI"
        case .cursor:     return "Cursor"
        case .amp:        return "Amp"
        case .droid:      return "Droid"
        }
    }

    /// Single-character monogram used in the 20pt row chip.
    var monogram: String {
        switch self {
        case .claudeCode: return "C"
        case .codex:      return "X"
        case .copilotCli: return "G"
        case .openCode:   return "O"
        case .geminiCli:  return "V"
        case .cursor:     return "U"
        case .amp:        return "A"
        case .droid:      return "D"
        }
    }

    /// Stable brand-ish color for the row chip and collapsed-pill legend.
    /// Returned as `NSColor` so this file stays free of SwiftUI imports —
    /// the view layer bridges to `Color(nsColor:)` at the call site.
    var color: NSColor {
        switch self {
        case .claudeCode: return NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.02, alpha: 1)
        case .codex:      return NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
        case .copilotCli: return NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1)
        case .openCode:   return NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.45, alpha: 1)
        case .geminiCli:  return NSColor(calibratedRed: 0.40, green: 0.66, blue: 0.95, alpha: 1)
        case .cursor:     return NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.90, alpha: 1)
        case .amp:        return NSColor(calibratedRed: 0.90, green: 0.26, blue: 0.36, alpha: 1)
        case .droid:      return NSColor(calibratedRed: 0.99, green: 0.81, blue: 0.24, alpha: 1)
        }
    }
}

/// Normalized session phase. Free-form `cmux set-status` values are mapped
/// into this small closed set via `IslandSessionPhase.from(rawValue:)`.
enum IslandSessionPhase: String, Hashable, Sendable {
    case running
    case idle
    case waiting
    case error
    case unknown

    /// Sort precedence for the island list: lower comes first.
    /// Running beats waiting beats error beats idle beats unknown.
    var rank: Int {
        switch self {
        case .running: return 0
        case .waiting: return 1
        case .error:   return 2
        case .idle:    return 3
        case .unknown: return 4
        }
    }

    /// Case-insensitive, trim-tolerant lookup from a free-form status value.
    static func from(rawValue: String) -> IslandSessionPhase {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "running", "running_tool", "processing", "starting":
            return .running
        case "", "idle", "ready":
            return .idle
        case "waiting", "waiting_for_input", "needs_input", "needsinput":
            return .waiting
        case "error", "failed", "failure":
            return .error
        default:
            return .unknown
        }
    }
}

/// One row in the cmux Island. Immutable value type; a fresh instance is
/// emitted whenever the upstream state changes.
struct IslandSession: Identifiable, Equatable, Comparable, Sendable {
    /// Stable identity equal to `panelId` — a single panel hosts at most one
    /// session in MVP scope.
    let id: UUID
    let workspaceId: UUID
    let panelId: UUID
    let agentKind: IslandAgentKind
    let phase: IslandSessionPhase
    let workspaceTitle: String
    let panelTitle: String
    let lastActivity: Date
    let unreadCount: Int
    /// Original free-form status value kept for debug/tooltip inspection.
    let rawStatusValue: String
}

extension IslandSession {
    /// Standard sort comparator. Running first, recent first on ties.
    ///
    /// Note: the tie-break uses `>` on `lastActivity` because "sorted before"
    /// for the island list means "more recent activity ranks first". Reading
    /// `>` inside a `<` operator is the correct inversion, not a bug.
    static func < (lhs: IslandSession, rhs: IslandSession) -> Bool {
        if lhs.phase.rank != rhs.phase.rank {
            return lhs.phase.rank < rhs.phase.rank
        }
        return lhs.lastActivity > rhs.lastActivity  // descending: newer activity ranks first
    }
}
