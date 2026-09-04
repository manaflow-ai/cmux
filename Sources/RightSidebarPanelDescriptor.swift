import AppKit
import CmuxAppKitSupportUI
import SwiftUI

/// Declarative metadata and content factory for one right-sidebar panel.
struct RightSidebarPanelDescriptor: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let order: Int
    let isAvailable: (UserDefaults) -> Bool
    let shortcutAction: KeyboardShortcutSettings.Action?
    let cliArgument: String
    /// Additional user-facing aliases accepted by CLI/socket entry points.
    let cliAliases: [String]
    let commandPaletteCommandID: String
    let paneCommandID: String?
    let paneTitle: String?
    let supportsTearOffPane: Bool
    let behavior: RightSidebarPanelBehavior
    let makeContent: @MainActor (RightSidebarPanelContext) -> AnyView
}
