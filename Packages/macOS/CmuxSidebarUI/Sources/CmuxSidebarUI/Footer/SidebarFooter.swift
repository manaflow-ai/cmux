public import AppKit
public import SwiftUI
public import CmuxUpdater
public import CmuxUpdaterUI

/// The sidebar footer container that selects the build-appropriate footer.
///
/// Release builds render ``SidebarFooterButtons`` with the footer's edge
/// padding; debug builds render ``SidebarDevFooter`` (the buttons plus the
/// dev-build banner). All inputs are app-resolved values/closures, so the
/// footer holds no app-target dependency: the help title and rows, the
/// extensions gate and title, the accent color, the update host, the
/// open-extension-browser closure, and the resolved dev-banner text.
public struct SidebarFooter: View {
    private let updateViewModel: UpdateStateModel
    private let helpTitle: String
    private let helpMenuOptions: [SidebarHelpMenuButton.Option]
    private let extensionsEnabled: Bool
    private let extensionsBrowserTitle: String
    private let onOpenExtensionBrowser: @MainActor (NSView?) -> Void
    private let accentColor: Color
    private let updateActionsHost: (any UpdateActionsHost)?
    private let devBuildBannerText: String

    /// Creates the sidebar footer.
    /// - Parameters:
    ///   - updateViewModel: The observable update state driving the update pill.
    ///   - helpTitle: Localized tooltip/accessibility label for the help button.
    ///   - helpMenuOptions: The ordered help-popover rows, built app-side.
    ///   - extensionsEnabled: Whether the experimental extensions feature is on.
    ///   - extensionsBrowserTitle: Localized extensions-browser title.
    ///   - onOpenExtensionBrowser: Opens the sidebar extension browser.
    ///   - accentColor: Host accent color for the update pill.
    ///   - updateActionsHost: The host that performs update actions.
    ///   - devBuildBannerText: Resolved (already localized) dev-build banner
    ///     text, used only by the debug footer.
    public init(
        updateViewModel: UpdateStateModel,
        helpTitle: String,
        helpMenuOptions: [SidebarHelpMenuButton.Option],
        extensionsEnabled: Bool,
        extensionsBrowserTitle: String,
        onOpenExtensionBrowser: @escaping @MainActor (NSView?) -> Void,
        accentColor: Color,
        updateActionsHost: (any UpdateActionsHost)?,
        devBuildBannerText: String
    ) {
        self.updateViewModel = updateViewModel
        self.helpTitle = helpTitle
        self.helpMenuOptions = helpMenuOptions
        self.extensionsEnabled = extensionsEnabled
        self.extensionsBrowserTitle = extensionsBrowserTitle
        self.onOpenExtensionBrowser = onOpenExtensionBrowser
        self.accentColor = accentColor
        self.updateActionsHost = updateActionsHost
        self.devBuildBannerText = devBuildBannerText
    }

    public var body: some View {
#if DEBUG
        SidebarDevFooter(
            updateViewModel: updateViewModel,
            helpTitle: helpTitle,
            helpMenuOptions: helpMenuOptions,
            extensionsEnabled: extensionsEnabled,
            extensionsBrowserTitle: extensionsBrowserTitle,
            onOpenExtensionBrowser: onOpenExtensionBrowser,
            accentColor: accentColor,
            updateActionsHost: updateActionsHost,
            devBuildBannerText: devBuildBannerText
        )
#else
        SidebarFooterButtons(
            updateViewModel: updateViewModel,
            helpTitle: helpTitle,
            helpMenuOptions: helpMenuOptions,
            extensionsEnabled: extensionsEnabled,
            extensionsBrowserTitle: extensionsBrowserTitle,
            onOpenExtensionBrowser: onOpenExtensionBrowser,
            accentColor: accentColor,
            updateActionsHost: updateActionsHost
        )
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
#endif
    }
}
