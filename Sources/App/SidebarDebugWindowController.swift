import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

final class SidebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SidebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidebar Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.sidebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private let githubURL = URL(string: "https://github.com/manaflow-ai/cmux")
    private let docsURL = URL(string: "https://cmux.com/docs")

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        if let value = Bundle.main.infoDictionary?["CMUXCommit"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["CMUX_COMMIT"] ?? ""
        return env.isEmpty ? nil : env
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text(String(localized: "about.appName", defaultValue: "cmux"))
                        .bold()
                        .font(.title)
                    Text(String(localized: "about.description", defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: String(localized: "about.version", defaultValue: "Version"), text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: String(localized: "about.build", defaultValue: "Build"), text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "https://github.com/manaflow-ai/cmux/commit/\(hash)")
                    }
                    AboutPropertyRow(label: String(localized: "about.commit", defaultValue: "Commit"), text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = docsURL {
                        Button(String(localized: "about.docs", defaultValue: "Docs")) {
                            openURL(url)
                        }
                    }
                    if let url = githubURL {
                        Button(String(localized: "about.github", defaultValue: "GitHub")) {
                            openURL(url)
                        }
                    }
                    Button(String(localized: "about.licenses", defaultValue: "Licenses")) {
                        AcknowledgmentsWindowController.shared.show()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}

struct SidebarDebugView: View {
    @AppStorage("sidebarMatchTerminalBackground") private var matchTerminalBackground = false
    @AppStorage("sidebarPreset") private var sidebarPreset = SidebarPresetOption.nativeSidebar.rawValue
    @AppStorage("sidebarTintOpacity") private var sidebarTintOpacity = SidebarTintDefaults.opacity
    @AppStorage("sidebarTintHex") private var sidebarTintHex = SidebarTintDefaults.hex
    @AppStorage("sidebarTintHexLight") private var sidebarTintHexLight: String?
    @AppStorage("sidebarTintHexDark") private var sidebarTintHexDark: String?
    @AppStorage("sidebarMaterial") private var sidebarMaterial = SidebarMaterialOption.sidebar.rawValue
    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarState") private var sidebarState = SidebarStateOption.followWindow.rawValue
    @AppStorage("sidebarCornerRadius") private var sidebarCornerRadius = 0.0
    @AppStorage("sidebarBlurOpacity") private var sidebarBlurOpacity = 1.0
    @AppStorage(SidebarBranchLayoutSettings.key) private var sidebarBranchVerticalLayout = SidebarBranchLayoutSettings.defaultVerticalLayout
    @AppStorage(SidebarBranchDirectoryStackedSettings.key) private var sidebarBranchDirectoryStacked = SidebarBranchDirectoryStackedSettings.defaultStacked
    @AppStorage(SidebarPathLastSegmentSettings.key) private var sidebarPathLastSegmentOnly = SidebarPathLastSegmentSettings.defaultLastSegmentOnly
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage("sidebarSelectionColorHex") private var sidebarSelectionColorHex: String?

    private var selectedSidebarIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
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
                return cmuxAccentColor()
            },
            set: { newColor in
                let nsColor = NSColor(newColor)
                sidebarSelectionColorHex = nsColor.hexString()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar"))
                    .font(.headline)

                Toggle(String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), isOn: $matchTerminalBackground)

                GroupBox("Presets") {
                    Picker("Preset", selection: $sidebarPreset) {
                        ForEach(SidebarPresetOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .onChange(of: sidebarPreset) { _ in
                        applyPreset()
                    }
                    .padding(.top, 2)
                }

                GroupBox("Blur") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Material", selection: $sidebarMaterial) {
                            ForEach(SidebarMaterialOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("Blending", selection: $sidebarBlendMode) {
                            ForEach(SidebarBlendModeOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }

                        Picker("State", selection: $sidebarState) {
                            ForEach(SidebarStateOption.allCases) { option in
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
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
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
                        sidebarTintOpacity = 0.62
                        sidebarTintHex = SidebarTintDefaults.hex
                        sidebarTintHexLight = nil
                        sidebarTintHexDark = nil
                    }
                    Button("Reset Blur") {
                        sidebarMaterial = SidebarMaterialOption.hudWindow.rawValue
                        sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
                        sidebarState = SidebarStateOption.active.rawValue
                        sidebarBlurOpacity = 0.98
                    }
                    Button("Reset Shape") {
                        sidebarCornerRadius = 0.0
                    }
                    Button("Reset Active Indicator") {
                        sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
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
        guard let preset = SidebarPresetOption(rawValue: sidebarPreset) else { return }
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

// MARK: - Menu Bar Extra Debug Window
