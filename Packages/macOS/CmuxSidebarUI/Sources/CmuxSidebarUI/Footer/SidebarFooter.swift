public import SwiftUI
public import CmuxUpdater
public import CmuxUpdaterUI
private import AppKit
private import CmuxAppKitSupportUI

/// The sidebar footer cluster: the help button, the optional extensions-browser
/// button, and the update pill, plus (on debug builds) the dev-build banner.
///
/// This view is pure presentation. Every app-target coupling the legacy
/// `ContentView` footer reached for is inverted into an injected value or
/// closure:
///
/// - The help-menu rows arrive as a caller-built ``SidebarHelpMenuButton/Option``
///   array (each title resolved app-side via `String(localized:)`, each effect a
///   closure), so the package never binds to the app bundle or names
///   `AppDelegate`/`BrowserDataImportCoordinator`.
/// - The extensions-browser button's open effect is the `openExtensionBrowser`
///   closure (handed the current anchor `NSView?`), and its visibility is the
///   `extensionsExperimentalEnabled` snapshot resolved app-side.
/// - The titlebar anchor used to position the extensions popover is supplied as a
///   `@ViewBuilder` `extensionAnchor` closure (the app passes its
///   `TitlebarControlAnchorView`), since that representable lives in the app
///   target.
/// - The update pill receives the observable ``UpdateStateModel``, the host
///   `accentColor`, and the optional `any UpdateActionsHost` to act through. The
///   pill is rendered only when that host is non-nil, faithful to the legacy
///   `if let updateActionsHost = AppDelegate.shared { UpdatePill(...) }` gate;
///   the help and extensions buttons render regardless.
/// - On debug builds the dev-build banner's visibility (`showDevBuildBanner`) and
///   text (`devBuildBannerText`) are both resolved app-side.
///
/// The view owns only the popover/anchor presentation state.
public struct SidebarFooter: View {
    private let updateViewModel: UpdateStateModel
    private let accentColor: Color
    private let updateActionsHost: (any UpdateActionsHost)?
    private let helpTitle: String
    private let helpMenuOptions: [SidebarHelpMenuButton.Option]
    private let extensionsExperimentalEnabled: Bool
    private let extensionsTitle: String
    private let openExtensionBrowser: (NSView?) -> Void
    private let extensionAnchor: (@escaping (NSView?) -> Void) -> AnyView
    private let showDevBuildBanner: Bool
    private let devBuildBannerText: String

    /// Creates the sidebar footer.
    /// - Parameters:
    ///   - updateViewModel: Observable update state driving the update pill.
    ///   - accentColor: Host accent color for the update pill (the app's
    ///     `cmuxAccentColor()`).
    ///   - updateActionsHost: Optional host that performs the update-pill
    ///     actions. The update pill renders only when this is non-nil (faithful
    ///     to the legacy `if let AppDelegate.shared` gate around the pill);
    ///     the help and extensions buttons render regardless.
    ///   - helpTitle: Localized tooltip/label for the help button.
    ///   - helpMenuOptions: Ordered help-popover rows, built app-side with
    ///     localized titles and app-target effect closures.
    ///   - extensionsExperimentalEnabled: Whether the experimental extensions
    ///     feature is enabled (gates the puzzle button).
    ///   - extensionsTitle: Localized title for the extensions-browser button
    ///     (used as tooltip/accessibility label and passed to the open effect by
    ///     the caller's closure).
    ///   - openExtensionBrowser: Opens the sidebar extension browser, given the
    ///     current anchor view.
    ///   - extensionAnchor: Builds the titlebar anchor view (the app's
    ///     `TitlebarControlAnchorView`) wired to report its backing `NSView`.
    ///   - showDevBuildBanner: Whether to show the debug dev-build banner.
    ///   - devBuildBannerText: Localized dev-build banner text.
    public init(
        updateViewModel: UpdateStateModel,
        accentColor: Color,
        updateActionsHost: (any UpdateActionsHost)?,
        helpTitle: String,
        helpMenuOptions: [SidebarHelpMenuButton.Option],
        extensionsExperimentalEnabled: Bool,
        extensionsTitle: String,
        openExtensionBrowser: @escaping (NSView?) -> Void,
        extensionAnchor: @escaping (@escaping (NSView?) -> Void) -> AnyView,
        showDevBuildBanner: Bool = false,
        devBuildBannerText: String = ""
    ) {
        self.updateViewModel = updateViewModel
        self.accentColor = accentColor
        self.updateActionsHost = updateActionsHost
        self.helpTitle = helpTitle
        self.helpMenuOptions = helpMenuOptions
        self.extensionsExperimentalEnabled = extensionsExperimentalEnabled
        self.extensionsTitle = extensionsTitle
        self.openExtensionBrowser = openExtensionBrowser
        self.extensionAnchor = extensionAnchor
        self.showDevBuildBanner = showDevBuildBanner
        self.devBuildBannerText = devBuildBannerText
    }

    public var body: some View {
#if DEBUG
        VStack(alignment: .leading, spacing: 6) {
            footerButtons
            if showDevBuildBanner {
                SidebarDevBuildBanner(text: devBuildBannerText)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
#else
        footerButtons
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
#endif
    }

    @State private var extensionBrowserAnchorView: NSView?

    private var footerButtons: some View {
        HStack(spacing: 4) {
            SidebarHelpMenuButton(
                helpTitle: helpTitle,
                options: helpMenuOptions
            )
            // The puzzle button opens the extensions browser; it only shows
            // while the experimental Extensions feature is enabled.
            if extensionsExperimentalEnabled {
                Button {
                    openExtensionBrowser(extensionBrowserAnchorView)
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 22, height: 22, alignment: .center)
                }
                .buttonStyle(SidebarFooterIconButtonStyle())
                .frame(width: 22, height: 22, alignment: .center)
                .safeHelp(extensionsTitle)
                .accessibilityLabel(extensionsTitle)
                .accessibilityIdentifier("SidebarExtensionMenuButton")
                .background(extensionAnchor { extensionBrowserAnchorView = $0 })
            }
            if let updateActionsHost {
                UpdatePill(model: updateViewModel, accent: accentColor, actions: updateActionsHost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
