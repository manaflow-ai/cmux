#if canImport(AppKit)

public import SwiftUI
// WorkspaceIndicatorStyle appears in this view's public init signature.
public import CmuxSettings

internal import AppKit
internal import CmuxFoundation

/// The Sidebar Debug editor: live controls for sidebar appearance (preset, blur,
/// tint, shape, active-workspace indicator, workspace metadata) backed by the
/// shared `@AppStorage` keys the running sidebar reads.
///
/// The view is byte-faithful to the panel that previously lived in the app
/// target. Two values that are irreducibly app-coupled are injected:
///
/// - ``accentColor``: the default selection color shown when no custom
///   `sidebarSelectionColorHex` is set. The app resolves this from its live
///   appearance (`cmuxAccentColor()`), which depends on app-target color logic.
/// - ``indicatorStyleDisplayName``: localized display strings for
///   ``WorkspaceIndicatorStyle``. They resolve against the app bundle (the
///   package bundle lacks the keys), so the app supplies the closure.
public struct SidebarDebugView: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @AppStorage("sidebarPreset") private var sidebarPreset = WindowChromeSidebarPresetOption.nativeSidebar.rawValue
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = WindowChromeSidebarTintDefaults().opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = WindowChromeSidebarTintDefaults().hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = WindowChromeSidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = WindowChromeSidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = WindowChromeSidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(SidebarCatalogSection().branchVerticalLayout.userDefaultsKey)
    private var sidebarBranchVerticalLayout = SidebarCatalogSection().branchVerticalLayout.defaultValue
    @AppStorage(SidebarCatalogSection().stackBranchDirectory.userDefaultsKey)
    private var sidebarBranchDirectoryStacked = SidebarCatalogSection().stackBranchDirectory.defaultValue
    @AppStorage(SidebarCatalogSection().pathLastSegmentOnly.userDefaultsKey)
    private var sidebarPathLastSegmentOnly = SidebarCatalogSection().pathLastSegmentOnly.defaultValue
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(WorkspaceColorsCatalogSection().indicatorStyle.userDefaultsKey)
    private var sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?

    private let accentColor: () -> Color
    private let indicatorStyleDisplayName: (WorkspaceIndicatorStyle) -> String

    /// Creates the editor.
    ///
    /// - Parameters:
    ///   - accentColor: Resolves the default selection color (shown when no
    ///     custom selection hex is set). Evaluated on each read so it tracks the
    ///     live app appearance, matching the legacy app-side `cmuxAccentColor()`.
    ///   - indicatorStyleDisplayName: Resolves the localized display string for a
    ///     ``WorkspaceIndicatorStyle`` against the app bundle.
    public init(
        accentColor: @escaping () -> Color,
        indicatorStyleDisplayName: @escaping (WorkspaceIndicatorStyle) -> String
    ) {
        self.accentColor = accentColor
        self.indicatorStyleDisplayName = indicatorStyleDisplayName
    }

    private var selectedSidebarIndicatorStyle: WorkspaceIndicatorStyle {
        WorkspaceIndicatorStyle.decodeFromUserDefaults(sidebarActiveTabIndicatorStyle)
            ?? WorkspaceColorsCatalogSection().indicatorStyle.defaultValue
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    private var selectionColorBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = sidebarSelectionColorHex, let nsColor = NSColor(hex: hex) {
                    return Color(nsColor: nsColor)
                }
                return accentColor()
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarSelectionColorHex = nsColor.hexString()
            }
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar"))
                    .font(.headline)

                Toggle(String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), isOn: $matchTerminalBackground)

                GroupBox("Presets") {
                    Picker("Preset", selection: $sidebarPreset) {
                        ForEach(WindowChromeSidebarPresetOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .onChange(of: sidebarPreset) {
                        applyPreset()
                    }
                    .padding(.top, 2)
                }

                GroupBox("Blur") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Material", selection: $sidebarMaterial) {
                            ForEach(WindowChromeSidebarMaterialOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("Blending", selection: $sidebarBlendMode) {
                            ForEach(WindowChromeSidebarBlendModeOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("State", selection: $sidebarState) {
                            ForEach(WindowChromeSidebarStateOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Strength")
                            Slider(value: $sidebarBlurOpacity, in: 0...1)
                            Text(String(format: "%.0f%%", sidebarBlurOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Tint") {
                    VStack(alignment: .leading, spacing: 8) {
                        ColorPicker("Tint Color", selection: tintColorBinding, supportsOpacity: false)

                        HStack(spacing: 8) {
                            Text("Opacity")
                            Slider(value: $sidebarTintOpacity, in: 0...0.7)
                            Text(String(format: "%.0f%%", sidebarTintOpacity * 100))
                                .font(.caption)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Shape") {
                    HStack(spacing: 8) {
                        Text("Corner Radius")
                        Slider(value: $sidebarCornerRadius, in: 0...20)
                        Text(String(format: "%.0f", sidebarCornerRadius))
                            .font(.caption)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(WorkspaceIndicatorStyle.allCases, id: \.self) { style in
                                Text(indicatorStyleDisplayName(style)).tag(style.rawValue)
                            }
                        }

                        ColorPicker(String(localized: "sidebar.debug.selectionColor", defaultValue: "Selection Color"), selection: selectionColorBinding, supportsOpacity: false)

                        if sidebarSelectionColorHex != nil {
                            Button(String(localized: "sidebar.debug.resetSelectionColor", defaultValue: "Reset to Default")) {
                                sidebarSelectionColorHex = nil
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Workspace Metadata") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Render branch list vertically", isOn: $sidebarBranchVerticalLayout)
                        Text("When enabled, each branch appears on its own line in the sidebar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 12) {
                    Button("Reset Tint") {
                        sidebarTintOpacity = WindowChromeSidebarTintDefaults().opacity
                        sidebarTintHex = WindowChromeSidebarTintDefaults().hex
                        sidebarTintHexLight = nil
                        sidebarTintHexDark = nil
                    }
                    Button("Reset Blur") {
                        sidebarMaterial = WindowChromeSidebarMaterialOption.hudWindow.rawValue
                        sidebarBlendMode = WindowChromeSidebarBlendModeOption.withinWindow.rawValue
                        sidebarState = WindowChromeSidebarStateOption.active.rawValue
                        sidebarBlurOpacity = 0.98
                    }
                    Button("Reset Shape") {
                        sidebarCornerRadius = 0.0
                    }
                    Button("Reset Active Indicator") {
                        sidebarActiveTabIndicatorStyle = WorkspaceColorsCatalogSection().indicatorStyle.defaultValue.rawValue
                        sidebarSelectionColorHex = nil
                    }
                }

                Button("Copy Config") {
                    copySidebarConfig()
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var tintColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hex: sidebarTintHex) ?? .black)
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarTintHex = nsColor.hexString()
            }
        )
    }

    private func copySidebarConfig() {
        let payload = """
        sidebarPreset=\(sidebarPreset)
        sidebarMaterial=\(sidebarMaterial)
        sidebarBlendMode=\(sidebarBlendMode)
        sidebarState=\(sidebarState)
        sidebarBlurOpacity=\(String(format: "%.2f", sidebarBlurOpacity))
        sidebarTintHex=\(sidebarTintHex)
        sidebarTintHexLight=\(sidebarTintHexLight ?? "(nil)")
        sidebarTintHexDark=\(sidebarTintHexDark ?? "(nil)")
        sidebarTintOpacity=\(String(format: "%.2f", sidebarTintOpacity))
        sidebarCornerRadius=\(String(format: "%.1f", sidebarCornerRadius))
        sidebarBranchVerticalLayout=\(sidebarBranchVerticalLayout)
        sidebarBranchDirectoryStacked=\(sidebarBranchDirectoryStacked)
        sidebarPathLastSegmentOnly=\(sidebarPathLastSegmentOnly)
        sidebarActiveTabIndicatorStyle=\(sidebarActiveTabIndicatorStyle)
        sidebarDevBuildBannerVisible=\(showSidebarDevBuildBanner)
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    private func applyPreset() {
        guard let preset = WindowChromeSidebarPresetOption(rawValue: sidebarPreset) else { return }
        sidebarMaterial = preset.material.rawValue
        sidebarBlendMode = preset.blendMode.rawValue
        sidebarState = preset.state.rawValue
        sidebarTintHex = preset.tintHex
        sidebarTintOpacity = preset.tintOpacity
        sidebarCornerRadius = preset.cornerRadius
        sidebarBlurOpacity = preset.blurOpacity
        sidebarTintHexLight = nil
        sidebarTintHexDark = nil
    }
}

#endif
