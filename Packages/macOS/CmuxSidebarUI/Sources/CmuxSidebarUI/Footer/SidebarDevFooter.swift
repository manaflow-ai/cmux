#if DEBUG
public import AppKit
public import SwiftUI
public import CmuxUpdater
public import CmuxUpdaterUI
private import CmuxFoundation

/// The debug-build sidebar footer: the footer button row plus, when enabled,
/// the red "THIS IS A DEV BUILD" banner.
///
/// The banner's visibility is gated by the debug ``DevBuildBannerDebugSettings``
/// `AppStorage` flag (read in-package since the flag's key and default are pure
/// values). The banner text itself is resolved (and localized) app-side and
/// passed in, so the view binds to no bundle and references no app-target type.
public struct SidebarDevFooter: View {
    private let updateViewModel: UpdateStateModel
    private let helpTitle: String
    private let helpMenuOptions: [SidebarHelpMenuButton.Option]
    private let extensionsEnabled: Bool
    private let extensionsBrowserTitle: String
    private let onOpenExtensionBrowser: @MainActor (NSView?) -> Void
    private let accentColor: Color
    private let updateActionsHost: (any UpdateActionsHost)?
    private let devBuildBannerText: String

    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    /// Creates the debug sidebar footer.
    /// - Parameters:
    ///   - updateViewModel: The observable update state driving the update pill.
    ///   - helpTitle: Localized tooltip/accessibility label for the help button.
    ///   - helpMenuOptions: The ordered help-popover rows, built app-side.
    ///   - extensionsEnabled: Whether the experimental extensions feature is on.
    ///   - extensionsBrowserTitle: Localized extensions-browser title.
    ///   - onOpenExtensionBrowser: Opens the sidebar extension browser.
    ///   - accentColor: Host accent color for the update pill.
    ///   - updateActionsHost: The host that performs update actions.
    ///   - devBuildBannerText: Resolved (already localized) dev-build banner text.
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
        VStack(alignment: .leading, spacing: 6) {
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
            if showSidebarDevBuildBanner {
                SidebarDevBuildBanner(text: devBuildBannerText)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif
