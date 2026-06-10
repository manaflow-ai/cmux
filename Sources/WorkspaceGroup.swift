import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Workspace Group Model & Placement Settings
/// Where a newly-created workspace lands inside its group when the user
/// clicks the group header's + button (or invokes
/// `workspace.group.new_workspace`).
///   - `.afterCurrent` — immediately after the current in-group workspace,
///     falling back to `.top` when no in-group reference is supplied.
///   - `.top` — second slot, immediately after the anchor.
///   - `.end` — last slot, after the existing trailing member.
enum WorkspaceGroupNewPlacement: String, Sendable, CaseIterable, Identifiable {
    case afterCurrent
    case top
    case end

    var id: String { rawValue }

    init?(rawString: String?) {
        guard let raw = rawString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "aftercurrent", "after-current", "after_current":
            self = .afterCurrent
        case "top":
            self = .top
        case "end":
            self = .end
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .afterCurrent:
            return String(localized: "workspaceGroup.placement.afterCurrent", defaultValue: "After current")
        case .top:
            return String(localized: "workspaceGroup.placement.top", defaultValue: "Top of group")
        case .end:
            return String(localized: "workspaceGroup.placement.end", defaultValue: "End of group")
        }
    }

    var settingsDescription: String {
        switch self {
        case .afterCurrent:
            return String(
                localized: "workspaceGroup.placement.afterCurrent.description",
                defaultValue: "Insert new group workspaces after the active workspace in that group."
            )
        case .top:
            return String(
                localized: "workspaceGroup.placement.top.description",
                defaultValue: "Insert new group workspaces right after the group header."
            )
        case .end:
            return String(
                localized: "workspaceGroup.placement.end.description",
                defaultValue: "Append new group workspaces after the last group member."
            )
        }
    }
}

/// UserDefaults-backed global default for the per-group `+` placement.
/// Used when neither the per-cwd `cmux.json` entry nor an explicit call-site
/// override pins a placement.
enum WorkspaceGroupNewWorkspacePlacementSettings {
    static let key = "workspaceGroup.newWorkspacePlacement"
    static let defaultValue: WorkspaceGroupNewPlacement = .afterCurrent

    static func resolved(defaults: UserDefaults = .standard) -> WorkspaceGroupNewPlacement {
        guard let raw = defaults.string(forKey: key),
              let value = WorkspaceGroupNewPlacement(rawString: raw) else {
            return defaultValue
        }
        return value
    }

    static func set(_ value: WorkspaceGroupNewPlacement, defaults: UserDefaults = .standard) {
        if value == defaultValue {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value.rawValue, forKey: key)
        }
    }
}

/// Named collapsible sidebar group containing one or more workspaces.
/// The membership relation lives on `Workspace.groupId`; this struct stores
/// the group's identity, display name, collapse/pin state, and the explicit
/// anchor workspace whose lifecycle gates the group itself.
///
/// The anchor workspace is always a real member workspace. It is created
/// fresh when the group is created (never promoted from an existing member),
/// rendered IMPLICITLY as the group header (no separate sidebar row), and
/// when closed dissolves the group while keeping other members alive.
struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var isCollapsed: Bool
    var isPinned: Bool
    /// Identifier of the member workspace that owns this group's lifecycle.
    /// Always present and always points to a workspace in `TabManager.tabs`
    /// whose `groupId == self.id`. Closing this workspace dissolves the group.
    var anchorWorkspaceId: UUID
    /// Group-level color override (hex string). When nil, falls back to the
    /// cwd-config color resolved from `cmux.json` for the anchor's cwd, then
    /// to no tint.
    var customColor: String?
    /// SF symbol name for the header icon. When nil, defaults to `folder.fill`.
    var iconSymbol: String?
}

