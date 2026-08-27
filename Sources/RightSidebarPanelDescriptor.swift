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
    let commandPaletteCommandID: String
    let paneCommandID: String?
    let paneTitle: String?
    let supportsTearOffPane: Bool
    let syncsFileExplorerRoot: Bool
    let makeContent: @MainActor (RightSidebarPanelContext) -> AnyView
}
