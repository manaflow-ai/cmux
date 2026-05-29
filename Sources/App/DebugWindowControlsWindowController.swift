import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

#if DEBUG
final class DebugWindowControlsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DebugWindowControlsWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Debug Window Controls"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.debugWindowControls")
        window.center()
        window.contentView = NSHostingView(rootView: DebugWindowControlsView())
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

struct DebugWindowControlsView: View {
    @AppStorage(SidebarActiveTabIndicatorSettings.styleKey)
    private var sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconNameKey) private var browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
    @AppStorage(BrowserDevToolsButtonDebugSettings.iconColorKey) private var browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue

    private var selectedDevToolsIconOption: BrowserDevToolsIconOption {
        BrowserDevToolsIconOption(rawValue: browserDevToolsIconNameRaw) ?? BrowserDevToolsButtonDebugSettings.defaultIcon
    }

    private var selectedDevToolsColorOption: BrowserDevToolsIconColorOption {
        BrowserDevToolsIconColorOption(rawValue: browserDevToolsIconColorRaw) ?? BrowserDevToolsButtonDebugSettings.defaultColor
    }

    private var selectedSidebarActiveTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: sidebarActiveTabIndicatorStyle)
    }

    private var sidebarIndicatorStyleSelection: Binding<String> {
        Binding(
            get: { selectedSidebarActiveTabIndicatorStyle.rawValue },
            set: { sidebarActiveTabIndicatorStyle = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug Window Controls")
                    .font(.headline)

                GroupBox("Open") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Browser Import Hint Debug…") {
                            BrowserImportHintDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.browserProfilePopoverDebug",
                                defaultValue: "Browser Profile Popover Debug…"
                            )
                        ) {
                            BrowserProfilePopoverDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.aboutTitlebarDebug",
                                defaultValue: "About Titlebar Debug…"
                            )
                        ) {
                            AboutTitlebarDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.titlebarLayoutDebug",
                                defaultValue: "Titlebar Layout Debug..."
                            )
                        ) {
                            TitlebarLayoutDebugWindowController.shared.show()
                        }
                        Button("Sidebar Debug…") {
                            SidebarDebugWindowController.shared.show()
                        }
                        Button("Background Debug…") {
                            BackgroundDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.bonsplitTabBarDebug",
                                defaultValue: "Bonsplit Tab Bar Debug…"
                            )
                        ) {
                            BonsplitTabBarDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.startupAppearanceDebug",
                                defaultValue: "Startup Appearance Debug…"
                            )
                        ) {
                            StartupAppearanceDebugWindowController.shared.show()
                        }
                        Button("Menu Bar Extra Debug…") {
                            MenuBarExtraDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.pdfPreviewChromeDebug",
                                defaultValue: "PDF Preview Chrome Debug…"
                            )
                        ) {
                            PDFPreviewChromeDebugWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.tabBarBackdropLab",
                                defaultValue: "Tab Bar Backdrop Lab…"
                            )
                        ) {
                            TabBarBackdropLabWindowController.shared.show()
                        }
                        Button(
                            String(
                                localized: "debug.menu.feedTextEditorDebug",
                                defaultValue: "Feed Text Editor Lab…"
                            )
                        ) {
                            FeedTextEditorDebugWindowController.shared.show()
                        }
                        Button("Open All Debug Windows") {
                            DebugWindowControlsWindowController.shared.show()
                            BrowserImportHintDebugWindowController.shared.show()
                            BrowserProfilePopoverDebugWindowController.shared.show()
                            AboutTitlebarDebugWindowController.shared.show()
                            TitlebarLayoutDebugWindowController.shared.show()
                            SidebarDebugWindowController.shared.show()
                            BackgroundDebugWindowController.shared.show()
                            BonsplitTabBarDebugWindowController.shared.show()
                            StartupAppearanceDebugWindowController.shared.show()
                            MenuBarExtraDebugWindowController.shared.show()
                            PDFPreviewChromeDebugWindowController.shared.show()
                            TabBarBackdropLabWindowController.shared.show()
                            FeedTextEditorDebugWindowController.shared.show()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                GroupBox("Active Workspace Indicator") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Style", selection: sidebarIndicatorStyleSelection) {
                            ForEach(SidebarActiveTabIndicatorStyle.allCases) { style in
                                Text(style.displayName).tag(style.rawValue)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Reset Indicator Style") {
                            sidebarActiveTabIndicatorStyle = SidebarActiveTabIndicatorSettings.defaultStyle.rawValue
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Browser DevTools Button") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Icon")
                            Picker("Icon", selection: $browserDevToolsIconNameRaw) {
                                ForEach(BrowserDevToolsIconOption.allCases) { option in
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
                                ForEach(BrowserDevToolsIconColorOption.allCases) { option in
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
                            Image(systemName: selectedDevToolsIconOption.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(selectedDevToolsColorOption.color)
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
                            DebugWindowConfigSnapshot.copyCombinedToPasteboard()
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

    private func resetBrowserDevToolsButton() {
        browserDevToolsIconNameRaw = BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
        browserDevToolsIconColorRaw = BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
    }

    private func copyBrowserDevToolsButtonConfig() {
        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: .standard)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}
#endif
