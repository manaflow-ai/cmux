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


// MARK: - Sidebar Display Settings
enum SidebarBranchLayoutSettings {
    static let key = "sidebarBranchVerticalLayout"
    static let defaultVerticalLayout = true

    static func usesVerticalLayout(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultVerticalLayout
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarBranchDirectoryStackedSettings {
    static let key = "sidebarBranchDirectoryStacked"
    static let defaultStacked = false

    static func isStacked(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultStacked
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarPathLastSegmentSettings {
    static let key = "sidebarPathLastSegmentOnly"
    static let defaultLastSegmentOnly = false

    static func isLastSegmentOnly(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultLastSegmentOnly
        }
        return defaults.bool(forKey: key)
    }
}

enum SidebarWorkspaceDetailSettings {
    static let hideAllDetailsKey = "sidebarHideAllDetails"
    static let showWorkspaceDescriptionKey = "sidebarShowWorkspaceDescription"
    static let showNotificationMessageKey = "sidebarShowNotificationMessage"
    static let defaultHideAllDetails = false
    static let defaultShowWorkspaceDescription = true
    static let defaultShowNotificationMessage = true

    static func hidesAllDetails(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: hideAllDetailsKey) == nil {
            return defaultHideAllDetails
        }
        return defaults.bool(forKey: hideAllDetailsKey)
    }

    static func showsWorkspaceDescription(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showWorkspaceDescriptionKey) == nil {
            return defaultShowWorkspaceDescription
        }
        return defaults.bool(forKey: showWorkspaceDescriptionKey)
    }

    static func showsNotificationMessage(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showNotificationMessageKey) == nil {
            return defaultShowNotificationMessage
        }
        return defaults.bool(forKey: showNotificationMessageKey)
    }

    static func resolvedWorkspaceDescriptionVisibility(
        showWorkspaceDescription: Bool,
        hideAllDetails: Bool
    ) -> Bool {
        showWorkspaceDescription && !hideAllDetails
    }

    static func resolvedNotificationMessageVisibility(
        showNotificationMessage: Bool,
        hideAllDetails: Bool
    ) -> Bool {
        showNotificationMessage && !hideAllDetails
    }
}

enum SidebarPullRequestClickabilitySettings {
    static let key = "sidebarMakePullRequestClickable"
    static let defaultClickable = true

    static func isClickable(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultClickable
        }
        return defaults.bool(forKey: key)
    }
}

struct SidebarWorkspaceAuxiliaryDetailVisibility: Equatable {
    let showsMetadata: Bool
    let showsLog: Bool
    let showsProgress: Bool
    let showsBranchDirectory: Bool
    let showsPullRequests: Bool
    let showsPorts: Bool

    static let hidden = Self(
        showsMetadata: false,
        showsLog: false,
        showsProgress: false,
        showsBranchDirectory: false,
        showsPullRequests: false,
        showsPorts: false
    )

    static func resolved(
        showMetadata: Bool,
        showLog: Bool,
        showProgress: Bool,
        showBranchDirectory: Bool,
        showPullRequests: Bool,
        showPorts: Bool,
        hideAllDetails: Bool
    ) -> Self {
        guard !hideAllDetails else { return .hidden }
        return Self(
            showsMetadata: showMetadata,
            showsLog: showLog,
            showsProgress: showProgress,
            showsBranchDirectory: showBranchDirectory,
            showsPullRequests: showPullRequests,
            showsPorts: showPorts
        )
    }
}

enum SidebarActiveTabIndicatorStyle: String, CaseIterable, Identifiable {
    case leftRail
    case solidFill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftRail:
            return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill:
            return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }
}

enum SidebarActiveTabIndicatorSettings {
    static let styleKey = "sidebarActiveTabIndicatorStyle"
    static let defaultStyle: SidebarActiveTabIndicatorStyle = .leftRail

    static func resolvedStyle(rawValue: String?) -> SidebarActiveTabIndicatorStyle {
        guard let rawValue else { return defaultStyle }
        if let style = SidebarActiveTabIndicatorStyle(rawValue: rawValue) {
            return style
        }

        // Legacy values from earlier iterations map to the closest modern option.
        switch rawValue {
        case "rail":
            return .leftRail
        case "border", "wash", "lift", "typography", "washRail", "blueWashColorRail":
            return .solidFill
        default:
            return defaultStyle
        }
    }

    static func current(defaults: UserDefaults = .standard) -> SidebarActiveTabIndicatorStyle {
        resolvedStyle(rawValue: defaults.string(forKey: styleKey))
    }
}

