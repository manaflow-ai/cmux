import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Startup Appearance Debug Window
final class StartupAppearanceDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = StartupAppearanceDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            localized: "debug.startupAppearance.window.title",
            defaultValue: "Startup Appearance Debug"
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.startupAppearanceDebug")
        window.center()
        window.contentView = NSHostingView(rootView: StartupAppearanceDebugView())
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

private enum StartupAppearancePreviewMode: String, CaseIterable, Identifiable {
    case stored
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
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
}

private struct StartupAppearanceDebugView: View {
    @State private var selectedProfile = GhosttyStartupAppearancePreviewState.profile
    @State private var selectedAppearance = StartupAppearancePreviewMode.stored
    @State private var lastAppliedProfile = GhosttyStartupAppearancePreviewState.profile
    @State private var lastAppliedAppearance = StartupAppearancePreviewMode.stored

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    String(
                        localized: "debug.startupAppearance.window.title",
                        defaultValue: "Startup Appearance Debug"
                    )
                )
                    .font(.headline)

                GroupBox(
                    String(
                        localized: "debug.startupAppearance.preview.heading",
                        defaultValue: "Preview"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            String(
                                localized: "debug.startupAppearance.startupConfig.label",
                                defaultValue: "Startup config"
                            ),
                            selection: $selectedProfile
                        ) {
                            ForEach(GhosttyStartupAppearancePreviewProfile.allCases) { profile in
                                Text(profile.displayName).tag(profile)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(selectedProfile.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker(
                            String(
                                localized: "debug.startupAppearance.appearance.label",
                                defaultValue: "Appearance"
                            ),
                            selection: $selectedAppearance
                        ) {
                            ForEach(StartupAppearancePreviewMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Button(
                                String(
                                    localized: "debug.startupAppearance.applyPreview.button",
                                    defaultValue: "Apply Preview"
                                )
                            ) {
                                applyPreview()
                            }
                            .keyboardShortcut(.defaultAction)

                            Button(
                                String(
                                    localized: "debug.startupAppearance.restoreRealStartup.button",
                                    defaultValue: "Restore Real Startup"
                                )
                            ) {
                                restoreRealStartup()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.startupAppearance.selectedConfig.heading",
                        defaultValue: "Selected Config"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView {
                            Text(selectedConfigText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(8)
                        }
                        .frame(minHeight: 92, maxHeight: 150)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button(
                            String(
                                localized: "debug.startupAppearance.copySelectedConfig.button",
                                defaultValue: "Copy Selected Config"
                            )
                        ) {
                            copySelectedConfig()
                        }
                        .disabled(selectedPreviewConfigText == nil)
                    }
                    .padding(.top, 2)
                }

                GroupBox(
                    String(
                        localized: "debug.startupAppearance.applied.heading",
                        defaultValue: "Applied"
                    )
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(
                                String(
                                    localized: "debug.startupAppearance.applied.configLabel",
                                    defaultValue: "Config:"
                                )
                            )
                            Text(lastAppliedProfile.displayName)
                        }
                        HStack(spacing: 4) {
                            Text(
                                String(
                                    localized: "debug.startupAppearance.applied.appearanceLabel",
                                    defaultValue: "Appearance:"
                                )
                            )
                            Text(lastAppliedAppearance.displayName)
                        }
                        Text(
                            String(
                                localized: "debug.startupAppearance.applied.help",
                                defaultValue: "Reloads the running app through Ghostty config update, matching startup theme resolution without editing config files."
                            )
                        )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    private var selectedPreviewConfigText: String? {
        selectedProfile.previewConfigContents()
    }

    private var selectedConfigText: String {
        selectedPreviewConfigText ?? String(
            localized: "debug.startupAppearance.realConfigFallback",
            defaultValue: "Loads real user config files."
        )
    }

    private func applyPreview() {
        applyAppearance(selectedAppearance)
        GhosttyStartupAppearancePreviewState.profile = selectedProfile
        GhosttyConfig.invalidateLoadCache()
        if let appDelegate = AppDelegate.shared {
            appDelegate.reloadConfiguration(
                source: "debug.startupAppearancePreview",
                reloadSettingsFromFile: false
            )
        } else {
            GhosttyApp.shared.reloadConfiguration(
                source: "debug.startupAppearancePreview",
                reloadSettingsFromFile: false
            )
        }
        lastAppliedProfile = selectedProfile
        lastAppliedAppearance = selectedAppearance
    }

    private func restoreRealStartup() {
        selectedProfile = .realUserConfig
        selectedAppearance = .stored
        applyAppearance(.stored)
        GhosttyStartupAppearancePreviewState.profile = .realUserConfig
        GhosttyConfig.invalidateLoadCache()
        if let appDelegate = AppDelegate.shared {
            appDelegate.reloadConfiguration(
                source: "debug.startupAppearanceRestore",
                reloadSettingsFromFile: false
            )
        } else {
            GhosttyApp.shared.reloadConfiguration(
                source: "debug.startupAppearanceRestore",
                reloadSettingsFromFile: false
            )
        }
        lastAppliedProfile = .realUserConfig
        lastAppliedAppearance = .stored
    }

    private func applyAppearance(_ mode: StartupAppearancePreviewMode) {
        switch mode {
        case .stored:
            switch AppearanceSettings.resolvedMode() {
            case .system, .auto:
                NSApplication.shared.appearance = nil
            case .light:
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func copySelectedConfig() {
        guard let config = selectedPreviewConfigText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(config, forType: .string)
    }
}

