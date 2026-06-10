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


// MARK: - Workspace Placement & Ordering Settings
enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return String(localized: "workspace.placement.top", defaultValue: "Top")
        case .afterCurrent:
            return String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")
        case .end:
            return String(localized: "workspace.placement.end", defaultValue: "End")
        }
    }

    var description: String {
        switch self {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum WorkspaceOrderChangeNotificationKey {
    static let movedWorkspaceIds = "movedWorkspaceIds"
}

struct WorkspaceReorderPlanItem: Equatable {
    let workspaceId: UUID
    let fromIndex: Int
    let toIndex: Int
}

enum WorkspaceBatchReorderError: Error, Equatable {
    case duplicateWorkspace(UUID)
    case workspaceNotFound(UUID)
}

enum LastSurfaceCloseShortcutSettings {
    static let key = "closeWorkspaceOnLastSurfaceShortcut"
    // Keep the legacy stored meaning so existing values still map to the same
    // behavior. The default is flipped to preserve the current Close Tab shortcut behavior.
    static let defaultValue = true

    static func closesWorkspace(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum WorkspacePlacementSettings {
    static let placementKey = "newWorkspacePlacement"
    static let defaultPlacement: NewWorkspacePlacement = .afterCurrent

    static func current(defaults: UserDefaults = .standard) -> NewWorkspacePlacement {
        guard let raw = defaults.string(forKey: placementKey),
              let placement = NewWorkspacePlacement(rawValue: raw) else {
            return defaultPlacement
        }
        return placement
    }

    static func effectivePlacement(
        placementOverride: NewWorkspacePlacement?,
        defaults: UserDefaults = .standard
    ) -> NewWorkspacePlacement {
        if let placementOverride {
            return placementOverride
        }
        if IMessageModeSettings.isEnabled(defaults: defaults) {
            return .top
        }
        return current(defaults: defaults)
    }

    static func insertionIndex(
        placement: NewWorkspacePlacement,
        selectedIndex: Int?,
        selectedIsPinned: Bool,
        pinnedCount: Int,
        totalCount: Int
    ) -> Int {
        let clampedTotalCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedTotalCount))

        switch placement {
        case .top:
            // Keep pinned workspaces grouped at the top by inserting ahead of unpinned items.
            return clampedPinnedCount
        case .end:
            return clampedTotalCount
        case .afterCurrent:
            guard let selectedIndex, clampedTotalCount > 0 else {
                return clampedTotalCount
            }
            let clampedSelectedIndex = max(0, min(selectedIndex, clampedTotalCount - 1))
            if selectedIsPinned {
                return clampedPinnedCount
            }
            return min(clampedSelectedIndex + 1, clampedTotalCount)
        }
    }
}

enum WorkspaceWorkingDirectoryInheritanceSettings {
    static let key = "workspaceInheritWorkingDirectory"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

/// UserDefaults-backed "Don't ask again" flag for the anchor-close confirm
/// dialog. Defaults to false (dialog is shown).
enum WorkspaceGroupAnchorCloseSettings {
    static let suppressionKey = "workspaceGroup.anchorCloseSuppressed"

    static func suppressed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: suppressionKey)
    }

    static func setSuppressed(_ value: Bool, defaults: UserDefaults = .standard) {
        if value {
            defaults.set(true, forKey: suppressionKey)
        } else {
            defaults.removeObject(forKey: suppressionKey)
        }
    }
}

