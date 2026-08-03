import AppKit
import CmuxFoundation
import CmuxWorkspaces

@MainActor
final class ConfigSettingsViewController: NSViewController, NSTextViewDelegate {
    static let windowID = "config-editor"
    static let windowIdentifier = NSUserInterfaceItemIdentifier("cmux.configEditor")

    private var configSource: ConfigSource = .cmux
    private var snapshots: [ConfigSource: ConfigSourceSnapshot] = [:]
    private var cmuxDraft = ""
    private var cmuxLastLoadedContents = ""
    private var configReloadTask: Task<Void, Never>?
    private var globalFontObserver: GlobalFontMagnificationChangeObserver?

    private let sourceControl = NSSegmentedControl(
        labels: ConfigSource.allCases.map(\.localizedTitle),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let pathsStack = NSStackView()
    private let bannerView = ConfigSettingsBannerView()
    private let editorScrollView = NSScrollView()
    private let editorTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let openEditorButton = NSButton()
    private let revealFinderButton = NSButton()
    private let reloadButton = NSButton()
    private let saveButton = NSButton()

    override func loadView() {
        view = ConfigSettingsRootView()
        configureControls()
        buildHierarchy()
        refreshSnapshots(preserveCmuxDraft: false)
        observeConfigurationReloads()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindow(view.window)
    }

    deinit {
        configReloadTask?.cancel()
    }

    private var currentSnapshot: ConfigSourceSnapshot {
        snapshots[configSource] ?? configSource.snapshot(environment: .live())
    }

    private var hasUnsavedCmuxChanges: Bool {
        cmuxDraft != cmuxLastLoadedContents
    }

    private var currentBannerText: String {
        switch configSource {
        case .cmux:
            String(
                localized: "settings.config.banner.cmux",
                defaultValue: "This is the cmux Ghostty config selected for this build. Edit it here, then Save to reload cmux."
            )
        case .synced where currentSnapshot.hasStandaloneGhosttyConfig:
            String(
                localized: "settings.config.banner.synced",
                defaultValue: "This is a generated preview of the effective config. Edit the cmux tab to change what cmux reads."
            )
        case .synced:
            String(
                localized: "settings.config.banner.syncedNoGhostty",
                defaultValue: "This is a generated preview of the effective config. No base Ghostty config file was found, so only cmux overrides are shown."
            )
        }
    }

    private func configureControls() {
        sourceControl.selectedSegment = ConfigSource.allCases.firstIndex(of: configSource) ?? 0
        sourceControl.target = self
        sourceControl.action = #selector(sourceDidChange(_:))
        sourceControl.setAccessibilityLabel(
            String(localized: "settings.config.source.label", defaultValue: "Config Source")
        )

        pathsStack.orientation = .vertical
        pathsStack.alignment = .leading
        pathsStack.spacing = 4

        editorScrollView.drawsBackground = true
        editorScrollView.backgroundColor = .textBackgroundColor
        editorScrollView.hasVerticalScroller = true
        editorScrollView.autohidesScrollers = true
        editorScrollView.borderType = .noBorder
        editorScrollView.wantsLayer = true
        editorScrollView.layer?.cornerRadius = 10
        editorScrollView.layer?.borderWidth = 1
        editorScrollView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor

        editorTextView.isRichText = false
        editorTextView.importsGraphics = false
        editorTextView.allowsUndo = true
        editorTextView.isSelectable = true
        editorTextView.textColor = .textColor
        editorTextView.backgroundColor = .textBackgroundColor
        editorTextView.insertionPointColor = .textColor
        editorTextView.textContainerInset = NSSize(width: 10, height: 10)
        editorTextView.autoresizingMask = [.width]
        editorTextView.isVerticallyResizable = true
        editorTextView.isHorizontallyResizable = false
        editorTextView.minSize = .zero
        editorTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editorTextView.textContainer?.widthTracksTextView = true
        editorTextView.textContainer?.containerSize = NSSize(
            width: editorScrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        editorTextView.delegate = self
        applyGlobalFont()
        globalFontObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyGlobalFont()
        }
        editorScrollView.documentView = editorTextView

        statusLabel.font = GlobalFontMagnification.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        configureButton(
            openEditorButton,
            action: #selector(openCurrentSourceInEditor),
            title: openEditorButtonTitle
        )
        configureButton(
            revealFinderButton,
            action: #selector(revealCurrentSourceInFinder),
            title: revealFinderButtonTitle
        )
        configureButton(
            reloadButton,
            action: #selector(reloadFromDisk),
            title: String(localized: "settings.config.action.reload", defaultValue: "Reload")
        )
        configureButton(
            saveButton,
            action: #selector(saveCmuxConfig),
            title: String(localized: "settings.config.action.save", defaultValue: "Save")
        )
        saveButton.keyEquivalent = "\r"
    }

    private func configureButton(_ button: NSButton, action: Selector, title: String) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
    }

    private func buildHierarchy() {
        let sourceRow = NSView()
        sourceControl.translatesAutoresizingMaskIntoConstraints = false
        sourceRow.addSubview(sourceControl)
        NSLayoutConstraint.activate([
            sourceControl.centerXAnchor.constraint(equalTo: sourceRow.centerXAnchor),
            sourceControl.topAnchor.constraint(equalTo: sourceRow.topAnchor),
            sourceControl.bottomAnchor.constraint(equalTo: sourceRow.bottomAnchor),
            sourceControl.widthAnchor.constraint(equalToConstant: 280),
        ])

        let separator = NSBox()
        separator.boxType = .separator

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [
            statusLabel,
            spacer,
            openEditorButton,
            revealFinderButton,
            reloadButton,
            saveButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let content = NSStackView(views: [
            sourceRow,
            separator,
            pathsStack,
            bannerView,
            editorScrollView,
            footer,
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        view.addSubview(content)

        for stretchedView in [sourceRow, separator, pathsStack, bannerView, editorScrollView, footer] {
            stretchedView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        editorScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        editorScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            editorScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 760),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 540),
        ])
    }

    private func observeConfigurationReloads() {
        configReloadTask?.cancel()
        configReloadTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .ghosttyConfigDidReload)
            for await _ in notifications {
                guard !Task.isCancelled, let self else { break }
                self.refreshSnapshots(preserveCmuxDraft: true)
            }
        }
    }

    private func configureWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.identifier = Self.windowIdentifier
        window.minSize = NSSize(width: 700, height: 500)
        window.tabbingMode = .disallowed
        window.animationBehavior = .utilityWindow
        window.adoptCmuxPeerWindowLevel()
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
        render()
    }

    private func render() {
        let displayedText = configSource == .cmux ? cmuxDraft : currentSnapshot.contents
        if editorTextView.string != displayedText {
            editorTextView.string = displayedText
        }
        editorTextView.isEditable = configSource == .cmux
        editorTextView.setAccessibilityIdentifier(
            configSource == .cmux ? "ConfigSettingsCmuxEditor" : "ConfigSettingsReadOnlyView"
        )

        pathsStack.arrangedSubviews.forEach {
            pathsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for path in currentSnapshot.displayPaths {
            let label = NSTextField(labelWithString: path)
            label.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.isSelectable = true
            pathsStack.addArrangedSubview(label)
        }

        bannerView.update(text: currentBannerText)
        openEditorButton.title = openEditorButtonTitle
        revealFinderButton.title = revealFinderButtonTitle
        saveButton.isEnabled = configSource == .cmux && hasUnsavedCmuxChanges
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

    @objc private func sourceDidChange(_ sender: NSSegmentedControl) {
        let sources = ConfigSource.allCases
        guard sources.indices.contains(sender.selectedSegment) else { return }
        configSource = sources[sender.selectedSegment]
        setStatus("")
        render()
    }

    @objc private func reloadFromDisk() {
        refreshSnapshots(preserveCmuxDraft: false)
        let completion: GhosttyApp.ConfigurationReloadCompletion = { [weak self] in
            self?.setStatus(
                String(
                    localized: "settings.config.status.reloaded",
                    defaultValue: "Reloaded configuration from disk."
                )
            )
        }
        let admitted = AppDelegate.shared?.reloadConfiguration(
            source: "settings.configWindow.reload",
            completion: completion
        ) ?? GhosttyApp.shared.reloadConfiguration(
            source: "settings.configWindow.reload",
            completion: completion
        )
        if !admitted {
            reportReloadAdmissionFailure()
        }
    }

    @objc private func saveCmuxConfig() {
        let environment = ConfigSourceEnvironment.live()
        do {
            try environment.writeCmuxConfigContents(cmuxDraft)
            cmuxLastLoadedContents = cmuxDraft
            refreshSnapshots(preserveCmuxDraft: true)
            let completion: GhosttyApp.ConfigurationReloadCompletion = { [weak self] in
                self?.setStatus(
                    String(
                        localized: "settings.config.status.saved",
                        defaultValue: "Saved to cmux config and reloaded."
                    )
                )
            }
            let admitted = AppDelegate.shared?.reloadConfiguration(
                source: "settings.configWindow.save",
                completion: completion
            ) ?? GhosttyApp.shared.reloadConfiguration(
                source: "settings.configWindow.save",
                completion: completion
            )
            if !admitted {
                reportReloadAdmissionFailure()
            }
        } catch {
            NSSound.beep()
            setStatus(
                String(
                    localized: "settings.config.status.saveFailed",
                    defaultValue: "Couldn't save the cmux config."
                ),
                isError: true
            )
        }
    }

    private func reportReloadAdmissionFailure() {
        setStatus(
            String(
                localized: "settings.config.status.reloadBusy",
                defaultValue: "Reload queued; too many requests are pending to confirm completion."
            ),
            isError: true
        )
    }

    @objc private func openCurrentSourceInEditor() {
        guard let url = materializedCmuxConfigURL() else { return }
        PreferredEditorService(defaults: .standard).open(url)
    }

    @objc private func revealCurrentSourceInFinder() {
        guard let url = materializedCmuxConfigURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func materializedCmuxConfigURL() -> URL? {
        do {
            return try ConfigSourceEnvironment.live().materializeCmuxConfigFileIfNeeded()
        } catch {
            NSSound.beep()
            setStatus(
                String(
                    localized: "settings.config.status.openFailed",
                    defaultValue: "Couldn't open the cmux config."
                ),
                isError: true
            )
            return nil
        }
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func applyGlobalFont() {
        editorTextView.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    func textDidChange(_ notification: Notification) {
        guard configSource == .cmux,
              notification.object as? NSTextView === editorTextView else { return }
        cmuxDraft = editorTextView.string
        saveButton.isEnabled = hasUnsavedCmuxChanges
    }
}

@MainActor
private final class ConfigSettingsRootView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class ConfigSettingsBannerView: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        iconView.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .secondaryLabelColor
        label.font = GlobalFontMagnification.systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    func update(text: String) {
        label.stringValue = text
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

private extension ConfigSource {
    var localizedTitle: String {
        switch self {
        case .cmux:
            String(localized: "settings.config.source.cmux", defaultValue: "cmux")
        case .synced:
            String(localized: "settings.config.source.synced", defaultValue: "synced")
        }
    }
}
