#if canImport(AppKit)
#if DEBUG

public import SwiftUI

internal import AppKit
internal import CmuxTerminalCore

/// The "Startup Appearance Debug" panel: live controls that exercise the Ghostty
/// startup-appearance pipeline without editing the user's real config.
///
/// The view is byte-faithful to the panel that previously lived in the app
/// target. Its app couplings are inverted: the three engine/appearance behaviors
/// go through the injected ``StartupAppearanceReloading`` seam, and every
/// user-facing label is resolved app-side and supplied through
/// ``StartupAppearanceDebugStrings`` (so `String(localized:)` binds to the app
/// bundle and keeps its non-English translations). The preview-profile selection
/// and synthetic config contents come from `CmuxTerminalCore`'s
/// ``GhosttyStartupAppearancePreviewState``/``GhosttyStartupAppearancePreviewProfile``;
/// this package owns no reference to the application delegate, the running engine,
/// or the app-target `AppearanceSettings`/`GhosttyConfig`.
public struct StartupAppearanceDebugView: View {
    @State private var selectedProfile = GhosttyStartupAppearancePreviewState.profile
    @State private var selectedAppearance = StartupAppearancePreviewMode.stored
    @State private var lastAppliedProfile = GhosttyStartupAppearancePreviewState.profile
    @State private var lastAppliedAppearance = StartupAppearancePreviewMode.stored

    private let reloading: any StartupAppearanceReloading
    private let strings: StartupAppearanceDebugStrings

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - reloading: The app-target seam that resolves the persisted appearance,
    ///     invalidates the engine's startup-config cache, and reloads the running
    ///     app's configuration.
    ///   - strings: The localized labels, resolved app-side against the app
    ///     bundle's catalog.
    public init(
        reloading: any StartupAppearanceReloading,
        strings: StartupAppearanceDebugStrings
    ) {
        self.reloading = reloading
        self.strings = strings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(strings.headerTitle)
                    .font(.headline)

                GroupBox(strings.previewHeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            strings.startupConfigLabel,
                            selection: $selectedProfile
                        ) {
                            ForEach(GhosttyStartupAppearancePreviewProfile.allCases) { profile in
                                Text(strings.profileDisplayName(profile)).tag(profile)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(strings.profileDetail(selectedProfile))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker(
                            strings.appearanceLabel,
                            selection: $selectedAppearance
                        ) {
                            ForEach(StartupAppearancePreviewMode.allCases) { mode in
                                Text(strings.modeDisplayName(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Button(strings.applyPreviewButton) {
                                applyPreview()
                            }
                            .keyboardShortcut(.defaultAction)

                            Button(strings.restoreRealStartupButton) {
                                restoreRealStartup()
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox(strings.selectedConfigHeading) {
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

                        Button(strings.copySelectedConfigButton) {
                            copySelectedConfig()
                        }
                        .disabled(selectedPreviewConfigText == nil)
                    }
                    .padding(.top, 2)
                }

                GroupBox(strings.appliedHeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(strings.appliedConfigLabel)
                            Text(strings.profileDisplayName(lastAppliedProfile))
                        }
                        HStack(spacing: 4) {
                            Text(strings.appliedAppearanceLabel)
                            Text(strings.modeDisplayName(lastAppliedAppearance))
                        }
                        Text(strings.appliedHelp)
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
        selectedPreviewConfigText ?? strings.realConfigFallback
    }

    private func applyPreview() {
        applyAppearance(selectedAppearance)
        GhosttyStartupAppearancePreviewState.profile = selectedProfile
        reloading.invalidateLoadCache()
        reloading.reloadConfiguration(source: "debug.startupAppearancePreview")
        lastAppliedProfile = selectedProfile
        lastAppliedAppearance = selectedAppearance
    }

    private func restoreRealStartup() {
        selectedProfile = .realUserConfig
        selectedAppearance = .stored
        applyAppearance(.stored)
        GhosttyStartupAppearancePreviewState.profile = .realUserConfig
        reloading.invalidateLoadCache()
        reloading.reloadConfiguration(source: "debug.startupAppearanceRestore")
        lastAppliedProfile = .realUserConfig
        lastAppliedAppearance = .stored
    }

    private func applyAppearance(_ mode: StartupAppearancePreviewMode) {
        switch mode {
        case .stored:
            switch reloading.resolvedAppearanceMode() {
            case .unspecified:
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

#endif
#endif
