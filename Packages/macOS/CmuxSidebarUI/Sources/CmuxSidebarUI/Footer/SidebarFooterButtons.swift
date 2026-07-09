public import AppKit
public import SwiftUI
public import CmuxUpdater
public import CmuxUpdaterUI
private import CmuxAppKitSupportUI

/// The sidebar footer's horizontal button row: the help popover button, the
/// optional extensions-browser puzzle button, and the update pill.
///
/// Every app-target dependency is inverted to a value or closure supplied by the
/// caller: the localized help title and the ordered ``SidebarHelpMenuButton/Option``
/// rows (each row's localized title and effect resolved app-side), whether the
/// experimental extensions feature is enabled, the resolved extensions-browser
/// title, the accent color, the update host, and the open-extension-browser
/// closure. The puzzle button still owns the `@State` titlebar-anchor `NSView`
/// it captures for the popover and hands to ``onOpenExtensionBrowser``, so the
/// view performs no `String(localized:)` and never references `AppDelegate`.
public struct SidebarFooterButtons: View {
    private let updateViewModel: UpdateStateModel
    private let helpTitle: String
    private let helpMenuOptions: [SidebarHelpMenuButton.Option]
    private let extensionsEnabled: Bool
    private let extensionsBrowserTitle: String
    private let onOpenExtensionBrowser: @MainActor (NSView?) -> Void
    private let accentColor: Color
    private let updateActionsHost: (any UpdateActionsHost)?

    @State private var extensionBrowserAnchorView: NSView?

    /// Creates the footer button row.
    /// - Parameters:
    ///   - updateViewModel: The observable update state driving the update pill.
    ///   - helpTitle: Localized tooltip/accessibility label for the help button.
    ///   - helpMenuOptions: The ordered help-popover rows, built app-side so each
    ///     localized title and effect is resolved in the app bundle.
    ///   - extensionsEnabled: Whether the experimental extensions feature is on,
    ///     gating the puzzle button.
    ///   - extensionsBrowserTitle: Localized title for the extensions browser,
    ///     used as the puzzle button's help/accessibility text.
    ///   - onOpenExtensionBrowser: Opens the sidebar extension browser, anchored
    ///     to the titlebar-control `NSView` captured for the popover.
    ///   - accentColor: Host accent color for the update pill's emphasis.
    ///   - updateActionsHost: The host that performs update actions; the pill is
    ///     omitted when `nil`.
    public init(
        updateViewModel: UpdateStateModel,
        helpTitle: String,
        helpMenuOptions: [SidebarHelpMenuButton.Option],
        extensionsEnabled: Bool,
        extensionsBrowserTitle: String,
        onOpenExtensionBrowser: @escaping @MainActor (NSView?) -> Void,
        accentColor: Color,
        updateActionsHost: (any UpdateActionsHost)?
    ) {
        self.updateViewModel = updateViewModel
        self.helpTitle = helpTitle
        self.helpMenuOptions = helpMenuOptions
        self.extensionsEnabled = extensionsEnabled
        self.extensionsBrowserTitle = extensionsBrowserTitle
        self.onOpenExtensionBrowser = onOpenExtensionBrowser
        self.accentColor = accentColor
        self.updateActionsHost = updateActionsHost
    }

    public var body: some View {
        HStack(spacing: 4) {
            SidebarHelpMenuButton(
                helpTitle: helpTitle,
                options: helpMenuOptions
            )
            // The puzzle button opens the extensions browser; it only shows
            // while the experimental Extensions feature is enabled.
            if extensionsEnabled {
                Button {
                    onOpenExtensionBrowser(extensionBrowserAnchorView)
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(SidebarFooterIconButtonStyle())
                .frame(width: 22, height: 22, alignment: .center)
                .safeHelp(extensionsBrowserTitle)
                .accessibilityLabel(extensionsBrowserTitle)
                .accessibilityIdentifier("SidebarExtensionMenuButton")
                .background(TitlebarControlAnchorView { extensionBrowserAnchorView = $0 })
            }
            if let updateActionsHost {
                UpdatePill(model: updateViewModel, accent: accentColor, actions: updateActionsHost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
