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


// MARK: - Notification Names & Keys
enum SidebarMultiSelectionCollapseKey {
    static let focusedWorkspaceId = "focusedWorkspaceId"
}

enum SidebarMultiSelectionHideKey {
    static let hiddenWorkspaceIds = "hiddenWorkspaceIds"
    static let focusedWorkspaceId = "focusedWorkspaceId"
}

extension Notification.Name {
    /// Posted when keyboard-nav focuses a single workspace and the sidebar's
    /// multi-selection state (SwiftUI @State Set<UUID> in VerticalTabsSidebar)
    /// should collapse to that workspace. Subscribers read
    /// `SidebarMultiSelectionCollapseKey.focusedWorkspaceId` from userInfo.
    static let sidebarMultiSelectionShouldCollapse = Notification.Name("cmux.sidebarMultiSelectionShouldCollapse")
    /// Posted when specific workspaces become hidden (group collapse). The
    /// SwiftUI sidebar should drop only those ids from its multi-selection
    /// without disturbing other entries. userInfo:
    /// `SidebarMultiSelectionHideKey.hiddenWorkspaceIds` (Set<UUID>), and
    /// optionally `SidebarMultiSelectionHideKey.focusedWorkspaceId` (UUID)
    /// when focus moved (so the focused row stays in the selection set).
    static let sidebarMultiSelectionDidHide = Notification.Name("cmux.sidebarMultiSelectionDidHide")
    static let commandPaletteToggleRequested = Notification.Name("cmux.commandPaletteToggleRequested")
    static let commandPaletteRequested = Notification.Name("cmux.commandPaletteRequested")
    static let commandPaletteSwitcherRequested = Notification.Name("cmux.commandPaletteSwitcherRequested")
    static let commandPaletteSubmitRequested = Notification.Name("cmux.commandPaletteSubmitRequested")
    static let commandPaletteDismissRequested = Notification.Name("cmux.commandPaletteDismissRequested")
    static let commandPaletteRenameTabRequested = Notification.Name("cmux.commandPaletteRenameTabRequested")
    static let commandPaletteRenameWorkspaceRequested = Notification.Name("cmux.commandPaletteRenameWorkspaceRequested")
    static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name("cmux.commandPaletteEditWorkspaceDescriptionRequested")
    static let commandPaletteMoveSelection = Notification.Name("cmux.commandPaletteMoveSelection")
    static let commandPaletteRenameInputInteractionRequested = Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
    static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
    static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
    static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    static let browserFocusModeStateDidChange = Notification.Name("cmux.browserFocusModeStateDidChange")
    static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
    static let terminalPortalVisibilityDidChange = Notification.Name("cmux.terminalPortalVisibilityDidChange")
    static let browserPortalRegistryDidChange = Notification.Name("cmux.browserPortalRegistryDidChange")
    static let workspaceOrderDidChange = Notification.Name("cmux.workspaceOrderDidChange")
    /// Posted when an existing workspace group's `name` changes (rename). The
    /// imperatively-cached window-chrome surfaces (custom title bar in
    /// `ContentView`, toolbar command label in `WindowToolbarController`) read
    /// a grouped anchor's displayed name from `group.name` and refresh on this.
    static let workspaceGroupNameDidChange = Notification.Name("cmux.workspaceGroupNameDidChange")
    static let workspaceCurrentDirectoryDidChange = Notification.Name("cmux.workspaceCurrentDirectoryDidChange")
    static let tabManagerFocusHistoryRevisionDidChange = Notification.Name("cmux.tabManagerFocusHistoryRevisionDidChange")
}

enum BrowserFirstResponderNotificationUserInfoKey {
    static let pointerInitiated = "pointerInitiated"
}
