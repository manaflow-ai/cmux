import AppKit
import CmuxAppKitSupportUI
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// App-target owner of the About / debug-window content builders that were
/// previously an all-static namespace cluster on the `AppDelegate` singleton
/// (`AppDelegate.aboutPanelStrings`, `AppDelegate.debugWindowControlsContentView`,
/// `AppDelegate.copyAllDebugConfig`, etc.). The cluster is irreducibly
/// app-coupled: the builders resolve `String(localized:)` against the app bundle,
/// snapshot live app-target runtime (`GhosttyApp.shared`, `Workspace`,
/// `WindowChromeMetrics`), present app-target debug windows through the
/// `DebugWindowsCoordinator`, and interpolate app-target settings enums into the
/// "Copy All Debug Config" payload, so it stays in the app target rather than a
/// package. Converting the statics to instance members on this
/// constructor-injected owner removes the static-as-namespace anti-pattern and
/// de-singletonizes `AppDelegate`.
///
/// The two dependencies are the only state the moved builders touch: the live
/// ``DebugWindowsCoordinator`` (resolved lazily through an injected closure so the
/// AppDelegate construction order between this provider and the coordinator stays
/// acyclic, and matching the former `AppDelegate.shared?.debugWindowsCoordinator`
/// no-op-if-absent semantics), and `UserDefaults.standard` (the Defaults store the
/// browser-DevTools reset/copy actions and the combined-config snapshot read and
/// write). Behavior is byte-faithful to the former statics.
@MainActor
final class DebugWindowControlsContentProvider {
    /// Lazily resolves the live ``DebugWindowsCoordinator`` (or `nil` if the
    /// AppDelegate is gone), preserving the former
    /// `AppDelegate.shared?.debugWindowsCoordinator` optional-chained semantics
    /// without referencing the singleton from the moved builders.
    private let debugWindowsCoordinatorProvider: @MainActor () -> DebugWindowsCoordinator?
    /// The Defaults store the browser-DevTools and combined-config builders read
    /// and write (`UserDefaults.standard` at the composition root).
    private let defaults: UserDefaults

    init(
        debugWindowsCoordinator: @escaping @MainActor () -> DebugWindowsCoordinator?,
        defaults: UserDefaults
    ) {
        self.debugWindowsCoordinatorProvider = debugWindowsCoordinator
        self.defaults = defaults
    }

    /// The live debug-windows coordinator, or `nil` when the host AppDelegate has
    /// been released. Faithful to `AppDelegate.shared?.debugWindowsCoordinator`.
    private var debugWindowsCoordinator: DebugWindowsCoordinator? {
        debugWindowsCoordinatorProvider()
    }

    /// Localized About-panel labels resolved against the app bundle and injected
    /// into the package-owned About window. Resolved app-side because
    /// `String(localized:)` inside `CmuxAppKitSupportUI` would bind to the package
    /// bundle (no `about.*` keys) and silently drop every non-English translation.
    var aboutPanelStrings: AboutPanelStrings {
        AboutPanelStrings(
            appName: String(localized: "about.appName", defaultValue: "cmux"),
            description: String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."),
            versionLabel: String(localized: "about.version", defaultValue: "Version"),
            buildLabel: String(localized: "about.build", defaultValue: "Build"),
            commitLabel: String(localized: "about.commit", defaultValue: "Commit"),
            docs: String(localized: "about.docs", defaultValue: "Docs"),
            github: String(localized: "about.github", defaultValue: "GitHub"),
            licenses: String(localized: "about.licenses", defaultValue: "Licenses")
        )
    }

    /// Localized Acknowledgments-window strings resolved against the app bundle and
    /// injected into the package-owned Acknowledgments window, for the same
    /// bundle-localization reason as ``aboutPanelStrings``.
    var acknowledgmentsStrings: AcknowledgmentsStrings {
        AcknowledgmentsStrings(
            windowTitle: String(localized: "about.licenses.windowTitle", defaultValue: "Third-Party Licenses"),
            notFound: String(localized: "about.licenses.notFound", defaultValue: "Licenses file not found.")
        )
    }

    /// Snapshot of the live backdrop tuning the package-owned Tab Bar Backdrop Lab
    /// previews. Captures the running terminal's default background color/opacity
    /// (`GhosttyApp.shared`) and the production split-button backdrop config
    /// (`Workspace`) at the moment the panel content is (re)built, matching the
    /// timing of the former in-view reads. The lab view itself lives in
    /// `CmuxAppKitSupportUI` and holds no reference to these app-target types.
    var tabBarBackdropLabInputs: TabBarBackdropLabInputs {
        TabBarBackdropLabInputs(
            defaultBackgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            defaultBackgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            productionBackdropSoftness: Workspace.bonsplitSplitButtonBackdropSoftness,
            productionBackdropEffect: Workspace.bonsplitSplitButtonBackdropEffect(),
            tabBarHeight: WindowChromeMetrics.bonsplitTabBarHeight
        )
    }

    #if DEBUG
    /// Localized labels for the package-owned "Startup Appearance Debug" panel,
    /// resolved app-side against the app bundle and injected, for the same
    /// bundle-localization reason as ``aboutPanelStrings``: `String(localized:)`
    /// inside `CmuxAppKitSupportUI` binds to the package bundle (no
    /// `debug.startupAppearance.*` keys) and would drop every non-English
    /// translation. The profile display strings reuse the app-side
    /// `GhosttyStartupAppearancePreviewProfile` presentation extension; the mode
    /// strings cover the package-local `StartupAppearancePreviewMode`.
    var startupAppearanceDebugStrings: StartupAppearanceDebugStrings {
        StartupAppearanceDebugStrings(
            headerTitle: String(
                localized: "debug.startupAppearance.window.title",
                defaultValue: "Startup Appearance Debug"
            ),
            previewHeading: String(
                localized: "debug.startupAppearance.preview.heading",
                defaultValue: "Preview"
            ),
            startupConfigLabel: String(
                localized: "debug.startupAppearance.startupConfig.label",
                defaultValue: "Startup config"
            ),
            appearanceLabel: String(
                localized: "debug.startupAppearance.appearance.label",
                defaultValue: "Appearance"
            ),
            applyPreviewButton: String(
                localized: "debug.startupAppearance.applyPreview.button",
                defaultValue: "Apply Preview"
            ),
            restoreRealStartupButton: String(
                localized: "debug.startupAppearance.restoreRealStartup.button",
                defaultValue: "Restore Real Startup"
            ),
            selectedConfigHeading: String(
                localized: "debug.startupAppearance.selectedConfig.heading",
                defaultValue: "Selected Config"
            ),
            copySelectedConfigButton: String(
                localized: "debug.startupAppearance.copySelectedConfig.button",
                defaultValue: "Copy Selected Config"
            ),
            realConfigFallback: String(
                localized: "debug.startupAppearance.realConfigFallback",
                defaultValue: "Loads real user config files."
            ),
            appliedHeading: String(
                localized: "debug.startupAppearance.applied.heading",
                defaultValue: "Applied"
            ),
            appliedConfigLabel: String(
                localized: "debug.startupAppearance.applied.configLabel",
                defaultValue: "Config:"
            ),
            appliedAppearanceLabel: String(
                localized: "debug.startupAppearance.applied.appearanceLabel",
                defaultValue: "Appearance:"
            ),
            appliedHelp: String(
                localized: "debug.startupAppearance.applied.help",
                defaultValue: "Reloads the running app through Ghostty config update, matching startup theme resolution without editing config files."
            ),
            profileDisplayName: { $0.displayName },
            profileDetail: { $0.detail },
            modeDisplayName: { mode in
                switch mode {
                case .stored:
                    return String(
                        localized: "debug.startupAppearance.mode.stored",
                        defaultValue: "Stored App Setting"
                    )
                case .light:
                    return String(
                        localized: "debug.startupAppearance.mode.light",
                        defaultValue: "Force Light"
                    )
                case .dark:
                    return String(
                        localized: "debug.startupAppearance.mode.dark",
                        defaultValue: "Force Dark"
                    )
                }
            }
        )
    }

    /// Builds the content view for the package-owned "Debug Window Controls" panel
    /// (`CmuxAppKitSupportUI`). The panel's window/lifecycle shell lives in the
    /// package, but its content is irreducibly app-coupled: the "Open" buttons
    /// present app-target debug windows, the browser DevTools pickers read the
    /// app-target `BrowserDevToolsButtonDebugSettings` enum (one color resolves the
    /// live app accent), the active-indicator labels resolve against the app bundle,
    /// and the "Copy All Debug Config" payload interpolates app-target settings
    /// enums. All of that is snapshotted/closed-over here and injected into the
    /// package view; the package holds no reference to those app-target types.
    var debugWindowControlsContentView: NSView {
        NSHostingView(rootView: DebugWindowControlsView(
            openActions: debugWindowControlsOpenActions,
            openAllAction: { self.openAllDebugWindows() },
            indicatorStyleDisplayName: { $0.displayName },
            browserDevToolsIconKey: BrowserDevToolsButtonDebugSettings.iconNameKey,
            browserDevToolsColorKey: BrowserDevToolsButtonDebugSettings.iconColorKey,
            browserDevToolsDefaultIconRaw: BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue,
            browserDevToolsDefaultColorRaw: BrowserDevToolsButtonDebugSettings.defaultColor.rawValue,
            browserDevToolsIconOptions: BrowserDevToolsIconOption.allCases.map {
                DebugBrowserDevToolsIconOption(rawValue: $0.rawValue, title: $0.title)
            },
            browserDevToolsColorOptions: BrowserDevToolsIconColorOption.allCases.map {
                DebugBrowserDevToolsColorOption(rawValue: $0.rawValue, title: $0.title, color: $0.color)
            },
            resetBrowserDevToolsButton: { self.resetBrowserDevToolsButton() },
            copyBrowserDevToolsButtonConfig: { self.copyBrowserDevToolsButtonConfig() },
            copyAllDebugConfig: { self.copyAllDebugConfig() }
        ))
    }

    /// The ordered "Open" buttons for the Debug Window Controls panel, snapshotted
    /// into package value rows. The titles are localized app-side and the closures
    /// present app-target debug windows; the order matches the legacy in-view list.
    private var debugWindowControlsOpenActions: [DebugWindowControlAction] {
        [
            DebugWindowControlAction(id: 0, title: "Browser Import Hint Debug…") {
                self.debugWindowsCoordinator?.showBrowserImportHintDebug()
            },
            DebugWindowControlAction(
                id: 1,
                title: String(
                    localized: "debug.menu.browserProfilePopoverDebug",
                    defaultValue: "Browser Profile Popover Debug…"
                )
            ) {
                self.debugWindowsCoordinator?.showBrowserProfilePopoverDebug()
            },
            DebugWindowControlAction(
                id: 2,
                title: String(
                    localized: "debug.menu.aboutTitlebarDebug",
                    defaultValue: "About Titlebar Debug…"
                )
            ) {
                self.debugWindowsCoordinator?.showAboutTitlebarDebugWindow()
            },
            DebugWindowControlAction(
                id: 3,
                title: String(
                    localized: "debug.menu.titlebarLayoutDebug",
                    defaultValue: "Titlebar Layout Debug..."
                )
            ) {
                TitlebarLayoutDebugWindowController.shared.show()
            },
            DebugWindowControlAction(id: 4, title: "Sidebar Debug…") {
                self.debugWindowsCoordinator?.showSidebarDebug()
            },
            DebugWindowControlAction(id: 5, title: "Background Debug…") {
                self.debugWindowsCoordinator?.showBackgroundDebug()
            },
            DebugWindowControlAction(
                id: 6,
                title: String(
                    localized: "debug.menu.bonsplitTabBarDebug",
                    defaultValue: "Bonsplit Tab Bar Debug…"
                )
            ) {
                BonsplitTabBarDebugWindowController.shared.show()
            },
            DebugWindowControlAction(
                id: 7,
                title: String(
                    localized: "debug.menu.startupAppearanceDebug",
                    defaultValue: "Startup Appearance Debug…"
                )
            ) {
                self.debugWindowsCoordinator?.showStartupAppearanceDebug()
            },
            DebugWindowControlAction(id: 8, title: "Menu Bar Extra Debug…") {
                self.debugWindowsCoordinator?.showMenuBarExtraDebug()
            },
            DebugWindowControlAction(
                id: 9,
                title: String(
                    localized: "debug.menu.pdfPreviewChromeDebug",
                    defaultValue: "PDF Preview Chrome Debug…"
                )
            ) {
                PDFPreviewChromeDebugWindowController.shared.show()
            },
            DebugWindowControlAction(
                id: 10,
                title: String(
                    localized: "debug.menu.tabBarBackdropLab",
                    defaultValue: "Tab Bar Backdrop Lab…"
                )
            ) {
                self.debugWindowsCoordinator?.showTabBarBackdropLab()
            },
            DebugWindowControlAction(
                id: 11,
                title: String(
                    localized: "debug.menu.feedTextEditorDebug",
                    defaultValue: "Feed Text Editor Lab…"
                )
            ) {
                FeedTextEditorDebugWindowController.shared.show()
            },
        ]
    }

    /// Opens every debug window, backing the panel's "Open All Debug Windows"
    /// button. Byte-faithful to the legacy in-view action.
    private func openAllDebugWindows() {
        debugWindowsCoordinator?.showDebugWindowControls()
        debugWindowsCoordinator?.showBrowserImportHintDebug()
        debugWindowsCoordinator?.showBrowserProfilePopoverDebug()
        debugWindowsCoordinator?.showAboutTitlebarDebugWindow()
        TitlebarLayoutDebugWindowController.shared.show()
        debugWindowsCoordinator?.showSidebarDebug()
        debugWindowsCoordinator?.showBackgroundDebug()
        BonsplitTabBarDebugWindowController.shared.show()
        debugWindowsCoordinator?.showStartupAppearanceDebug()
        debugWindowsCoordinator?.showMenuBarExtraDebug()
        PDFPreviewChromeDebugWindowController.shared.show()
        debugWindowsCoordinator?.showTabBarBackdropLab()
        FeedTextEditorDebugWindowController.shared.show()
    }

    /// Resets the browser DevTools button to its defaults. Byte-faithful to the
    /// legacy in-view action (writes the two Defaults keys directly).
    private func resetBrowserDevToolsButton() {
        defaults.set(
            BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue,
            forKey: BrowserDevToolsButtonDebugSettings.iconNameKey
        )
        defaults.set(
            BrowserDevToolsButtonDebugSettings.defaultColor.rawValue,
            forKey: BrowserDevToolsButtonDebugSettings.iconColorKey
        )
    }

    /// Copies the browser DevTools button config payload to the pasteboard.
    /// Byte-faithful to the legacy in-view action.
    private func copyBrowserDevToolsButtonConfig() {
        let payload = BrowserDevToolsButtonDebugSettings(defaults: defaults).copyPayload()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    /// Copies the combined sidebar/titlebar/background/menu-bar/browser-devtools
    /// snapshot via the package `DebugWindowConfigSnapshotService`. The service owns
    /// the generic UserDefaults-coercion helpers and the pasteboard plumbing; the
    /// combined payload text stays here because it interpolates app-target settings
    /// enums and catalog-section keys, so it is supplied through the injected closure
    /// (the service is captured to reuse its coercion helpers). Byte-faithful to the
    /// legacy in-view action.
    private func copyAllDebugConfig() {
        var service: DebugWindowConfigSnapshotService?
        let built = DebugWindowConfigSnapshotService(defaults: defaults) {
            guard let service else { return "" }
            return self.combinedDebugConfigPayload(using: service)
        }
        service = built
        built.copyCombinedToPasteboard()
    }

    private func combinedDebugConfigPayload(
        using service: DebugWindowConfigSnapshotService
    ) -> String {
        let defaults = service.defaults
        let sidebarPayload = """
        sidebarPreset=\(service.stringValue(key: "sidebarPreset", fallback: SidebarPresetOption.nativeSidebar.rawValue))
        sidebarMaterial=\(service.stringValue(key: "sidebarMaterial", fallback: SidebarMaterialOption.sidebar.rawValue))
        sidebarBlendMode=\(service.stringValue(key: "sidebarBlendMode", fallback: SidebarBlendModeOption.withinWindow.rawValue))
        sidebarState=\(service.stringValue(key: "sidebarState", fallback: SidebarStateOption.followWindow.rawValue))
        sidebarBlurOpacity=\(String(format: "%.2f", service.doubleValue(key: "sidebarBlurOpacity", fallback: 1.0)))
        sidebarTintHex=\(service.stringValue(key: "sidebarTintHex", fallback: "#000000"))
        sidebarTintHexLight=\(service.stringValue(key: "sidebarTintHexLight", fallback: "(nil)"))
        sidebarTintHexDark=\(service.stringValue(key: "sidebarTintHexDark", fallback: "(nil)"))
        sidebarTintOpacity=\(String(format: "%.2f", service.doubleValue(key: "sidebarTintOpacity", fallback: 0.18)))
        sidebarCornerRadius=\(String(format: "%.1f", service.doubleValue(key: "sidebarCornerRadius", fallback: 0.0)))
        sidebarBranchVerticalLayout=\(service.boolValue(key: SidebarCatalogSection().branchVerticalLayout.userDefaultsKey, fallback: SidebarCatalogSection().branchVerticalLayout.defaultValue))
        sidebarBranchDirectoryStacked=\(service.boolValue(key: SidebarCatalogSection().stackBranchDirectory.userDefaultsKey, fallback: SidebarCatalogSection().stackBranchDirectory.defaultValue))
        sidebarPathLastSegmentOnly=\(service.boolValue(key: SidebarCatalogSection().pathLastSegmentOnly.userDefaultsKey, fallback: SidebarCatalogSection().pathLastSegmentOnly.defaultValue))
        sidebarActiveTabIndicatorStyle=\(service.stringValue(key: WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey, fallback: WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue))
        sidebarDevBuildBannerVisible=\(service.boolValue(key: DevBuildBannerDebugSettings.sidebarBannerVisibleKey, fallback: DevBuildBannerDebugSettings.defaultShowSidebarBanner))
        sidebarMinimumWidth=\(String(format: "%.1f", SessionPersistencePolicy.resolvedMinimumSidebarWidth(defaults: defaults)))
        """

        let backgroundPayload = """
        bgGlassEnabled=\(service.boolValue(key: "bgGlassEnabled", fallback: false))
        bgGlassMaterial=\(service.stringValue(key: "bgGlassMaterial", fallback: "hudWindow"))
        bgGlassTintHex=\(service.stringValue(key: "bgGlassTintHex", fallback: "#000000"))
        bgGlassTintOpacity=\(String(format: "%.2f", service.doubleValue(key: "bgGlassTintOpacity", fallback: 0.03)))
        """

        let menuBarPayload = MenuBarIconDebugSettings.copyPayload(defaults: defaults)
        let browserDevToolsPayload = BrowserDevToolsButtonDebugSettings(defaults: defaults).copyPayload()
        let titlebarLayoutPayload = TitlebarLayoutDebugSettingsSnapshot.copyPayload(defaults: defaults)

        return """
        # Sidebar Debug
        \(sidebarPayload)

        # Titlebar Layout Debug
        \(titlebarLayoutPayload)

        # Background Debug
        \(backgroundPayload)

        # Menu Bar Extra Debug
        \(menuBarPayload)

        # Browser DevTools Button
        \(browserDevToolsPayload)
        """
    }
    #endif
}
