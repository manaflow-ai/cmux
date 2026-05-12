import AppKit
import SwiftUI

struct ConfigSettingsView: View {
    static let windowID = "config-editor"

    @State private var configSource: ConfigSource = .cmux
    @State private var snapshots: [ConfigSource: ConfigSourceSnapshot] = [:]
    @State private var cmuxDraft = ""
    @State private var cmuxLastLoadedContents = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false

    private var currentSnapshot: ConfigSourceSnapshot {
        snapshots[configSource] ?? configSource.snapshot(environment: .live())
    }

    private var hasUnsavedCmuxChanges: Bool {
        cmuxDraft != cmuxLastLoadedContents
    }

    private var currentBannerText: String? {
        switch configSource {
        case .cmux:
            return String(
                localized: "settings.config.banner.cmux",
                defaultValue: "This is the cmux Ghostty config selected for this build. Edit it here, then Save to reload cmux."
            )
        case .synced:
            if currentSnapshot.hasStandaloneGhosttyConfig {
                return String(
                    localized: "settings.config.banner.synced",
                    defaultValue: "This is a generated preview of the effective config. Edit the cmux tab to change what cmux reads."
                )
            }
            return String(
                localized: "settings.config.banner.syncedNoGhostty",
                defaultValue: "This is a generated preview of the effective config. No base Ghostty config file was found, so only cmux overrides are shown."
            )
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                Picker(
                    String(localized: "settings.config.source.label", defaultValue: "Config Source"),
                    selection: $configSource
                ) {
                    ForEach(ConfigSource.allCases) { source in
                        Text(source.localizedTitle).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer(minLength: 0)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                ForEach(currentSnapshot.displayPaths, id: \.self) { path in
                    Text(verbatim: path)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let bannerText = currentBannerText {
                ConfigSettingsBanner(text: bannerText)
            }

            Group {
                if configSource == .cmux {
                    ConfigSettingsTextView(text: $cmuxDraft, isEditable: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(editorBackground)
                        .accessibilityIdentifier("ConfigSettingsCmuxEditor")
                } else {
                    ConfigSettingsTextView(text: .constant(currentSnapshot.contents), isEditable: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(editorBackground)
                    .accessibilityIdentifier("ConfigSettingsReadOnlyView")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(statusIsError ? .red : .secondary)
                }

                Spacer(minLength: 0)

                Button(openEditorButtonTitle) {
                    openCurrentSourceInEditor()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(revealFinderButtonTitle) {
                    revealCurrentSourceInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "settings.config.action.reload", defaultValue: "Reload")) {
                    reloadFromDisk()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "settings.config.action.save", defaultValue: "Save")) {
                    saveCmuxConfig()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(configSource != .cmux || !hasUnsavedCmuxChanges)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .background(
            WindowAccessor { window in
                configureWindow(window)
            }
        )
        .onAppear {
            refreshSnapshots(preserveCmuxDraft: false)
        }
        .onChange(of: configSource) { _ in
            statusMessage = ""
            statusIsError = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshSnapshots(preserveCmuxDraft: true)
        }
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private var openEditorButtonTitle: String {
        if configSource == .synced {
            return String(
                localized: "settings.config.action.openActiveEditor",
                defaultValue: "Open Active Config…"
            )
        }
        return String(localized: "settings.config.action.openEditor", defaultValue: "Open in Editor…")
    }

    private var revealFinderButtonTitle: String {
        if configSource == .synced {
            return String(
                localized: "settings.config.action.revealActiveFinder",
                defaultValue: "Reveal Active Config in Finder"
            )
        }
        return String(localized: "settings.config.action.revealFinder", defaultValue: "Reveal in Finder")
    }

    private func configureWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cmux.configEditor")
        window.minSize = NSSize(width: 700, height: 500)
        window.tabbingMode = .disallowed
        window.animationBehavior = .utilityWindow
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }

    private func refreshSnapshots(preserveCmuxDraft: Bool) {
        let wasDirty = hasUnsavedCmuxChanges
        let environment = ConfigSourceEnvironment.live()
        let newSnapshots = Dictionary(
            uniqueKeysWithValues: ConfigSource.allCases.map { source in
                (source, source.snapshot(environment: environment))
            }
        )
        snapshots = newSnapshots

        let latestCmuxContents = newSnapshots[.cmux]?.contents ?? ""
        if !preserveCmuxDraft || !wasDirty {
            cmuxDraft = latestCmuxContents
        }
        cmuxLastLoadedContents = latestCmuxContents
    }

    private func reloadFromDisk() {
        refreshSnapshots(preserveCmuxDraft: false)
        GhosttyApp.shared.reloadConfiguration(source: "settings.configWindow.reload")
        statusMessage = String(
            localized: "settings.config.status.reloaded",
            defaultValue: "Reloaded configuration from disk."
        )
        statusIsError = false
    }

    private func saveCmuxConfig() {
        let environment = ConfigSourceEnvironment.live()

        do {
            try environment.writeCmuxConfigContents(cmuxDraft)
            cmuxLastLoadedContents = cmuxDraft
            refreshSnapshots(preserveCmuxDraft: true)
            GhosttyApp.shared.reloadConfiguration(source: "settings.configWindow.save")
            statusMessage = String(
                localized: "settings.config.status.saved",
                defaultValue: "Saved to cmux config and reloaded."
            )
            statusIsError = false
        } catch {
            NSSound.beep()
            statusMessage = String(
                localized: "settings.config.status.saveFailed",
                defaultValue: "Couldn't save the cmux config."
            )
            statusIsError = true
        }
    }

    private func openCurrentSourceInEditor() {
        guard let url = materializedCmuxConfigURL() else { return }
        PreferredEditorSettings.open(url)
    }

    private func revealCurrentSourceInFinder() {
        guard let url = materializedCmuxConfigURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func materializedCmuxConfigURL() -> URL? {
        let environment = ConfigSourceEnvironment.live()
        do {
            return try environment.materializeCmuxConfigFileIfNeeded()
        } catch {
            NSSound.beep()
            statusMessage = String(
                localized: "settings.config.status.openFailed",
                defaultValue: "Couldn't open the cmux config."
            )
            statusIsError = true
            return nil
        }
    }
}

private struct ConfigSettingsBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ConfigSettingsTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text

        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private extension ConfigSource {
    var localizedTitle: String {
        switch self {
        case .cmux:
            return String(localized: "settings.config.source.cmux", defaultValue: "cmux")
        case .synced:
            return String(localized: "settings.config.source.synced", defaultValue: "synced")
        }
    }
}
