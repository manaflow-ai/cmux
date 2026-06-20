#if canImport(AppKit)
#if DEBUG

public import SwiftUI
// WorkspaceIndicatorStyle appears in this view's init signature and picker.
public import CmuxSettings

/// The "Debug Window Controls" panel: a launcher for the app's other debug/lab
/// windows plus inline editors for the active-workspace indicator style, the
/// browser DevTools toolbar button, and a combined config copy action.
///
/// The view is byte-faithful to the panel that previously lived in the app
/// target. The active-workspace indicator GroupBox reads and writes the shared
/// `WorkspaceColorsCatalogSection().indicatorStyle` `@AppStorage` key directly
/// (the same Defaults key the running sidebar reads), and the browser DevTools
/// pickers read and write the `browserDevToolsIconName`/`browserDevToolsIconColor`
/// keys directly, so the wire/Defaults contract is unchanged.
///
/// Everything that is irreducibly app-coupled is injected:
///
/// - ``openActions`` / ``openAllAction``: the "Open" buttons present app-target
///   debug windows through app-target window controllers and the app's
///   ``DebugWindowsCoordinator`` call sites, so the app snapshots the ordered
///   button list (localized titles + open closures) and the "open all" closure.
/// - ``indicatorStyleDisplayName``: localized display strings for
///   ``WorkspaceIndicatorStyle`` resolve against the app bundle (the package
///   bundle lacks the keys), so the app supplies the closure.
/// - the browser DevTools option lists, default raw values, and the reset/copy
///   closures: the source `BrowserDevToolsIconOption`/`BrowserDevToolsIconColorOption`
///   enums and `BrowserDevToolsButtonDebugSettings` live in the app target (and one
///   color resolves the live app accent color), so the app snapshots the option
///   rows and supplies the reset/copy closures and persisted keys/defaults.
/// - ``copyAllDebugConfig``: the combined snapshot interpolates app-target settings
///   enums and catalog-section keys, so the app supplies the closure (it captures
///   a ``DebugWindowConfigSnapshotService`` for the coercion + pasteboard halves).
///
/// The package view therefore holds no reference to the app-target debug
/// controllers, settings enums, accent-color logic, or the application delegate.
public struct DebugWindowControlsView: View {
    @AppStorage(WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey)
    private var sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue

    private let browserDevToolsIconKey: String
    private let browserDevToolsColorKey: String

    @AppStorage private var browserDevToolsIconNameRaw: String
    @AppStorage private var browserDevToolsIconColorRaw: String

    private let openActions: [DebugWindowControlAction]
    private let openAllAction: @MainActor () -> Void
    private let indicatorStyleDisplayName: (WorkspaceIndicatorStyle) -> String
    private let browserDevToolsIconOptions: [DebugBrowserDevToolsIconOption]
    private let browserDevToolsColorOptions: [DebugBrowserDevToolsColorOption]
    private let browserDevToolsDefaultIconRaw: String
    private let browserDevToolsDefaultColorRaw: String
    private let resetBrowserDevToolsButton: @MainActor () -> Void
    private let copyBrowserDevToolsButtonConfig: @MainActor () -> Void
    private let copyAllDebugConfig: @MainActor () -> Void

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - openActions: The ordered "Open" buttons (localized titles + open
    ///     closures), snapshotted from the legacy app-side button list.
    ///   - openAllAction: Presents every debug window, backing the legacy "Open All
    ///     Debug Windows" button.
    ///   - indicatorStyleDisplayName: Resolves the localized display string for a
    ///     ``WorkspaceIndicatorStyle`` against the app bundle.
    ///   - browserDevToolsIconKey: The `browserDevToolsIconName` `UserDefaults` key.
    ///   - browserDevToolsColorKey: The `browserDevToolsIconColor` `UserDefaults`
    ///     key.
    ///   - browserDevToolsDefaultIconRaw: The default icon raw value, used to seed
    ///     the `@AppStorage` and to resolve the preview when the stored value is
    ///     not a known option (matching the legacy default fallback).
    ///   - browserDevToolsDefaultColorRaw: The default color raw value, used the
    ///     same way as `browserDevToolsDefaultIconRaw`.
    ///   - browserDevToolsIconOptions: The ordered icon option rows, snapshotted
    ///     from the app-target `BrowserDevToolsIconOption.allCases`.
    ///   - browserDevToolsColorOptions: The ordered color option rows (with
    ///     app-resolved preview colors), snapshotted from the app-target
    ///     `BrowserDevToolsIconColorOption.allCases`.
    ///   - resetBrowserDevToolsButton: Resets the browser DevTools button to its
    ///     defaults (writes the two Defaults keys app-side, matching the legacy
    ///     reset).
    ///   - copyBrowserDevToolsButtonConfig: Copies the browser DevTools button
    ///     config payload to the pasteboard.
    ///   - copyAllDebugConfig: Copies the combined sidebar/titlebar/background/menu
    ///     bar/browser-devtools snapshot to the pasteboard.
    public init(
        openActions: [DebugWindowControlAction],
        openAllAction: @escaping @MainActor () -> Void,
        indicatorStyleDisplayName: @escaping (WorkspaceIndicatorStyle) -> String,
        browserDevToolsIconKey: String,
        browserDevToolsColorKey: String,
        browserDevToolsDefaultIconRaw: String,
        browserDevToolsDefaultColorRaw: String,
        browserDevToolsIconOptions: [DebugBrowserDevToolsIconOption],
        browserDevToolsColorOptions: [DebugBrowserDevToolsColorOption],
        resetBrowserDevToolsButton: @escaping @MainActor () -> Void,
        copyBrowserDevToolsButtonConfig: @escaping @MainActor () -> Void,
        copyAllDebugConfig: @escaping @MainActor () -> Void
    ) {
        self.openActions = openActions
        self.openAllAction = openAllAction
        self.indicatorStyleDisplayName = indicatorStyleDisplayName
        self.browserDevToolsIconKey = browserDevToolsIconKey
        self.browserDevToolsColorKey = browserDevToolsColorKey
        self.browserDevToolsDefaultIconRaw = browserDevToolsDefaultIconRaw
        self.browserDevToolsDefaultColorRaw = browserDevToolsDefaultColorRaw
        self.browserDevToolsIconOptions = browserDevToolsIconOptions
        self.browserDevToolsColorOptions = browserDevToolsColorOptions
        self.resetBrowserDevToolsButton = resetBrowserDevToolsButton
        self.copyBrowserDevToolsButtonConfig = copyBrowserDevToolsButtonConfig
        self.copyAllDebugConfig = copyAllDebugConfig
        _browserDevToolsIconNameRaw = AppStorage(
            wrappedValue: browserDevToolsDefaultIconRaw,
            browserDevToolsIconKey
        )
        _browserDevToolsIconColorRaw = AppStorage(
            wrappedValue: browserDevToolsDefaultColorRaw,
            browserDevToolsColorKey
        )
    }

    private var selectedDevToolsIconSymbol: String {
        browserDevToolsIconOptions.contains(where: { $0.rawValue == browserDevToolsIconNameRaw })
            ? browserDevToolsIconNameRaw
            : browserDevToolsDefaultIconRaw
    }

    private var selectedDevToolsColor: Color {
        let raw = browserDevToolsColorOptions.contains(where: { $0.rawValue == browserDevToolsIconColorRaw })
            ? browserDevToolsIconColorRaw
            : browserDevToolsDefaultColorRaw
        return browserDevToolsColorOptions.first(where: { $0.rawValue == raw })?.color ?? .primary
    }

    private var selectedSidebarActiveTabIndicatorStyle: WorkspaceIndicatorStyle {
        WorkspaceIndicatorStyle.decodeFromUserDefaults(sidebarActiveTabIndicatorStyle)
            ?? WorkspaceColorsCatalogSection().indicatorStyle.defaultValue
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug Window Controls")
                    .font(.headline)

                GroupBox("Open") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(openActions) { entry in
                            Button(entry.title) {
                                entry.action()
                            }
                        }
                        Button("Open All Debug Windows") {
                            openAllAction()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(WorkspaceIndicatorStyle.allCases, id: \.self) { style in
                                Text(indicatorStyleDisplayName(style)).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Reset Indicator Style") {
                            sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Browser DevTools Button") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Icon")
                            Picker("Icon", selection: $browserDevToolsIconNameRaw) {
                                ForEach(browserDevToolsIconOptions) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Color")
                            Picker("Color", selection: $browserDevToolsIconColorRaw) {
                                ForEach(browserDevToolsColorOptions) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("Preview")
                            Spacer()
                            Image(systemName: selectedDevToolsIconSymbol)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedDevToolsColor)
                        }

                        HStack(spacing: 12) {
                            Button("Reset Button") {
                                resetBrowserDevToolsButton()
                            }
                            Button("Copy Button Config") {
                                copyBrowserDevToolsButtonConfig()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Copy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Copy All Debug Config") {
                            copyAllDebugConfig()
                        }
                        Text("Copies sidebar, background, menu bar, and browser devtools settings as one payload.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#endif
#endif
