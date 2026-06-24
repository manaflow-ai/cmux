import AppKit
import CmuxBrowser
import Foundation

/// The three-step modal AppKit wizard that lets the user pick a source browser,
/// choose source profiles, and select data types / destination profiles before
/// a browser-data import runs.
///
/// Presented modally by ``BrowserDataImportCoordinator`` via ``runModal()``,
/// which returns the confirmed ``BrowserImportSelection`` or `nil` on cancel.
/// Destination-profile lookups (current profiles, last-used fallback, display
/// names) go through an injected ``BrowserImportProfileResolving`` so the wizard
/// never references the app's concrete profile store.
@MainActor
final class BrowserImportWizardWindowController: NSObject, @preconcurrency NSWindowDelegate {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private enum Step {
        case source
        case sourceProfiles
        case dataTypes
    }

    private let browsers: [InstalledBrowserCandidate]
    private let destinationProfiles: [BrowserProfileDefinition]
    private let initialDestinationProfileID: UUID
    private let defaultScope: BrowserImportScope?
    /// The cmux profile store seam used for display names and id lookups.
    private let profileResolver: any BrowserImportProfileResolving
    /// Held detector instance used to summarize the detected browsers, rather
    /// than the former `BrowserInstalledBrowserDetector` static namespace.
    private let installedBrowserDetector = BrowserInstalledBrowserDetector()

    private var step: Step = .source
    private var didFinishModal = false
    private(set) var selection: BrowserImportSelection?
    private var selectedSourceProfileIDsByBrowserID: [String: Set<String>] = [:]
    private var sourceProfileCheckboxes: [NSButton] = []
    private var destinationMode: BrowserImportDestinationMode = .singleDestination
    private var separateExecutionEntries: [BrowserImportExecutionEntry] = []
    private var separateDestinationOptionsByEntryIndex: [Int: [BrowserImportDestinationRequest]] = [:]
    private var mergeDestinationProfileID: UUID

    private let panel: NSPanel

    private let stepLabel = NSTextField(labelWithString: "")
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourceContainer = NSStackView()
    private let sourceProfilesContainer = NSStackView()
    private let sourceProfilesList = NSStackView()
    private let sourceProfilesDocumentView = FlippedDocumentView(frame: .zero)
    private let sourceProfilesEmptyLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceProfilesHelpLabel = NSTextField(labelWithString: "")
    private let sourceProfilesScrollView = NSScrollView()
    private var sourceProfilesScrollHeightConstraint: NSLayoutConstraint?
    private let dataTypesContainer = NSStackView()
    private let validationLabel = NSTextField(labelWithString: "")
    private let destinationModeContainer = NSStackView()
    private let separateProfilesRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let mergeProfilesRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let separateDestinationRows = NSStackView()
    private let mergeDestinationRow = NSStackView()
    private let mergeDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destinationHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let additionalDataNoteLabel = NSTextField(wrappingLabelWithString: "")

    private let cookiesCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let additionalDataCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let domainField = NSTextField(frame: .zero)

    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)

    init(
        browsers: [InstalledBrowserCandidate],
        destinationProfiles: [BrowserProfileDefinition]?,
        defaultDestinationProfileID: UUID?,
        defaultScope: BrowserImportScope?,
        profileResolver: any BrowserImportProfileResolving
    ) {
        let resolvedDestinationProfiles = destinationProfiles ?? profileResolver.profiles
        let fallbackDestinationProfileID = resolvedDestinationProfiles.first?.id
            ?? profileResolver.effectiveLastUsedProfileID
        self.browsers = browsers
        self.destinationProfiles = resolvedDestinationProfiles
        self.initialDestinationProfileID = defaultDestinationProfileID
            .flatMap { candidateID in resolvedDestinationProfiles.first(where: { $0.id == candidateID })?.id }
            ?? fallbackDestinationProfileID
        self.defaultScope = defaultScope
        self.profileResolver = profileResolver
        self.mergeDestinationProfileID = self.initialDestinationProfileID
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 292),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        setupUI()
        configureInitialState()
    }

    func runModal() -> BrowserImportSelection? {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let response = NSApp.runModal(for: panel)
        if panel.isVisible {
            panel.orderOut(nil)
        }

        guard response == .OK else { return nil }
        return selection
    }

#if DEBUG
    var debugPanelWindow: NSWindow { panel }
#endif

    func windowWillClose(_ notification: Notification) {
        finishModal(with: .cancel)
    }

    @objc
    private func handleBack() {
        switch step {
        case .source:
            return
        case .sourceProfiles:
            step = .source
        case .dataTypes:
            step = .sourceProfiles
        }
        validationLabel.isHidden = true
        updateStepUI()
    }

    @objc
    private func handleCancel() {
        finishModal(with: .cancel)
    }

    @objc
    private func handlePrimary() {
        switch step {
        case .source:
            step = .sourceProfiles
            validationLabel.isHidden = true
            refreshSourceProfilesList()
            updateStepUI()
        case .sourceProfiles:
            let selectedSourceProfiles = selectedSourceProfiles()
            guard !selectedSourceProfiles.isEmpty else {
                validationLabel.stringValue = String(
                    localized: "browser.import.validation.sourceProfiles",
                    defaultValue: "Choose at least one source profile to import.",
                    bundle: .module
                )
                validationLabel.isHidden = false
                return
            }

            resetStep3State()
            step = .dataTypes
            validationLabel.isHidden = true
            updateStepUI()
        case .dataTypes:
            let includeCookies = cookiesCheckbox.state == .on
            let includeHistory = historyCheckbox.state == .on
            let includeAdditionalData = additionalDataCheckbox.state == .on
            guard let scope = BrowserImportScope.fromSelection(
                includeCookies: includeCookies,
                includeHistory: includeHistory,
                includeAdditionalData: includeAdditionalData
            ) else {
                validationLabel.stringValue = String(
                    localized: "browser.import.validation.scope",
                    defaultValue: "Select Cookies, History, or both before starting import.",
                    bundle: .module
                )
                validationLabel.isHidden = false
                return
            }

            let selectedBrowser = selectedBrowser()
            let domainFilters = BrowserDataImporter.parseDomainFilters(domainField.stringValue)
            selection = BrowserImportSelection(
                browser: selectedBrowser,
                executionPlan: currentExecutionPlan(),
                scope: scope,
                domainFilters: domainFilters
            )
            finishModal(with: .OK)
        }
    }

    @objc
    private func handleSourceChanged() {
        validationLabel.isHidden = true
        refreshSourceProfilesList()
        updateStepUI()
    }

    @objc
    private func handleSourceProfileToggled(_ sender: NSButton) {
        guard let profileID = sender.identifier?.rawValue else { return }
        let browserID = selectedBrowser().id
        var selectedIDs = storedSelectedSourceProfileIDs(for: selectedBrowser())
        if sender.state == .on {
            selectedIDs.insert(profileID)
        } else {
            selectedIDs.remove(profileID)
        }
        selectedSourceProfileIDsByBrowserID[browserID] = selectedIDs
        validationLabel.isHidden = true
    }

    @objc
    private func handleDestinationModeChanged(_ sender: NSButton) {
        let selectedSourceProfiles = selectedSourceProfiles()
        guard selectedSourceProfiles.count > 1 else { return }
        destinationMode = sender == separateProfilesRadio ? .separateProfiles : .mergeIntoOne
        rebuildStep3DestinationUI()
        updatePanelSize()
    }

    @objc
    private func handleMergeDestinationChanged(_ sender: NSPopUpButton) {
        let selectedIndex = max(0, min(sender.indexOfSelectedItem, destinationProfiles.count - 1))
        guard destinationProfiles.indices.contains(selectedIndex) else { return }
        mergeDestinationProfileID = destinationProfiles[selectedIndex].id
        validationLabel.isHidden = true
    }

    @objc
    private func handleSeparateDestinationChanged(_ sender: NSPopUpButton) {
        let entryIndex = sender.tag
        guard separateExecutionEntries.indices.contains(entryIndex),
              let options = separateDestinationOptionsByEntryIndex[entryIndex],
              options.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        separateExecutionEntries[entryIndex].destination = options[sender.indexOfSelectedItem]
        validationLabel.isHidden = true
    }

    @objc
    private func handleImportOptionChanged(_ sender: NSButton) {
        validationLabel.isHidden = true
        updateAdditionalDataNoteVisibility()
        updatePanelSize()
    }

    private func setupUI() {
        panel.title = String(
            localized: "browser.import.title",
            defaultValue: "Import Browser Data",
            bundle: .module
        )
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 292))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        let titleLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.title",
                defaultValue: "Import Browser Data",
                bundle: .module
            )
        )
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        stepLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stepLabel.textColor = .secondaryLabelColor

        setupSourceContainer()
        setupSourceProfilesContainer()
        setupDataTypesContainer()

        validationLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 3
        validationLabel.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(handleBack)
        backButton.bezelStyle = .rounded
        backButton.title = String(localized: "browser.import.back", defaultValue: "Back", bundle: .module)

        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.title = String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)
        cancelButton.keyEquivalent = "\u{1b}"

        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)
        primaryButton.bezelStyle = .rounded
        primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next", bundle: .module)
        primaryButton.keyEquivalent = "\r"

        let buttonSpacer = NSView(frame: .zero)

        let buttonRow = NSStackView(views: [buttonSpacer, backButton, cancelButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let contentStack = NSStackView(views: [
            titleLabel,
            stepLabel,
            sourceContainer,
            sourceProfilesContainer,
            dataTypesContainer,
            validationLabel,
        ])
        contentStack.orientation = .vertical
        contentStack.spacing = 8
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        sourceContainer.translatesAutoresizingMaskIntoConstraints = false
        sourceProfilesContainer.translatesAutoresizingMaskIntoConstraints = false
        dataTypesContainer.translatesAutoresizingMaskIntoConstraints = false

        guard let panelContent = panel.contentView else { return }
        panelContent.addSubview(contentStack)
        panelContent.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: panelContent.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -18),

            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 14),
            buttonRow.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 18),
            buttonRow.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor, constant: -14),

            sourceContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            sourceProfilesContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            dataTypesContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }

    private func setupSourceContainer() {
        for browser in browsers {
            sourcePopup.addItem(withTitle: browser.displayName)
        }
        sourcePopup.selectItem(at: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(handleSourceChanged)

        let sourceLabel = NSTextField(
            labelWithString: String(localized: "browser.import.source", defaultValue: "Source", bundle: .module)
        )
        sourceLabel.alignment = .right
        sourceLabel.frame.size.width = 64

        sourcePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourcePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sourceRow = NSStackView(views: [sourceLabel, sourcePopup])
        sourceRow.orientation = .horizontal
        sourceRow.spacing = 8
        sourceRow.alignment = .centerY
        sourceRow.distribution = .fill

        let detectedLabel = NSTextField(
            wrappingLabelWithString: installedBrowserDetector.summaryText(for: browsers)
        )
        detectedLabel.font = NSFont.systemFont(ofSize: 11)
        detectedLabel.textColor = .secondaryLabelColor
        detectedLabel.maximumNumberOfLines = 2
        detectedLabel.preferredMaxLayoutWidth = 500

        sourceContainer.orientation = .vertical
        sourceContainer.spacing = 8
        sourceContainer.alignment = .leading
        sourceContainer.addArrangedSubview(sourceRow)
        sourceContainer.addArrangedSubview(detectedLabel)
    }

    private func setupSourceProfilesContainer() {
        let sourceProfilesTitle = NSTextField(
            labelWithString: String(
                localized: "browser.import.sourceProfiles",
                defaultValue: "Source Profiles",
                bundle: .module
            )
        )
        sourceProfilesTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        sourceProfilesList.orientation = .vertical
        sourceProfilesList.spacing = 6
        sourceProfilesList.alignment = .leading
        sourceProfilesList.translatesAutoresizingMaskIntoConstraints = false

        sourceProfilesEmptyLabel.font = NSFont.systemFont(ofSize: 12)
        sourceProfilesEmptyLabel.textColor = .secondaryLabelColor
        sourceProfilesEmptyLabel.maximumNumberOfLines = 0
        sourceProfilesEmptyLabel.preferredMaxLayoutWidth = 500

        sourceProfilesDocumentView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        sourceProfilesDocumentView.translatesAutoresizingMaskIntoConstraints = false
        sourceProfilesDocumentView.addSubview(sourceProfilesList)
        NSLayoutConstraint.activate([
            sourceProfilesList.topAnchor.constraint(equalTo: sourceProfilesDocumentView.topAnchor),
            sourceProfilesList.leadingAnchor.constraint(equalTo: sourceProfilesDocumentView.leadingAnchor),
            sourceProfilesList.trailingAnchor.constraint(equalTo: sourceProfilesDocumentView.trailingAnchor),
            sourceProfilesList.bottomAnchor.constraint(equalTo: sourceProfilesDocumentView.bottomAnchor),
            sourceProfilesList.widthAnchor.constraint(equalTo: sourceProfilesDocumentView.widthAnchor),
        ])

        sourceProfilesScrollView.drawsBackground = false
        sourceProfilesScrollView.borderType = .bezelBorder
        sourceProfilesScrollView.hasVerticalScroller = true
        sourceProfilesScrollView.documentView = sourceProfilesDocumentView
        sourceProfilesScrollView.translatesAutoresizingMaskIntoConstraints = false
        sourceProfilesScrollView.contentView.postsBoundsChangedNotifications = true
        sourceProfilesScrollHeightConstraint = sourceProfilesScrollView.heightAnchor.constraint(equalToConstant: 76)
        sourceProfilesScrollHeightConstraint?.isActive = true
        let sourceProfilesScrollWidthConstraint = sourceProfilesScrollView.widthAnchor.constraint(
            equalTo: sourceProfilesContainer.widthAnchor
        )

        sourceProfilesHelpLabel.font = NSFont.systemFont(ofSize: 11)
        sourceProfilesHelpLabel.textColor = .secondaryLabelColor
        sourceProfilesHelpLabel.maximumNumberOfLines = 2
        sourceProfilesHelpLabel.lineBreakMode = .byWordWrapping
        sourceProfilesHelpLabel.preferredMaxLayoutWidth = 500
        sourceProfilesHelpLabel.stringValue = String(
            localized: "browser.import.sourceProfiles.help",
            defaultValue: "Choose one or more source profiles. Step 3 lets you keep them separate or merge them into one cmux profile.",
            bundle: .module
        )

        sourceProfilesContainer.orientation = .vertical
        sourceProfilesContainer.spacing = 8
        sourceProfilesContainer.alignment = .leading
        sourceProfilesContainer.addArrangedSubview(sourceProfilesTitle)
        sourceProfilesContainer.addArrangedSubview(sourceProfilesScrollView)
        sourceProfilesContainer.addArrangedSubview(sourceProfilesHelpLabel)
        sourceProfilesScrollWidthConstraint.isActive = true
        sourceProfilesContainer.setHuggingPriority(.defaultLow, for: .vertical)
        sourceProfilesContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func setupDataTypesContainer() {
        let initialScope = defaultScope ?? .cookiesAndHistory
        cookiesCheckbox.state = initialScope.includesCookies ? .on : .off
        historyCheckbox.state = initialScope.includesHistory ? .on : .off
        additionalDataCheckbox.state = initialScope == .everything ? .on : .off
        cookiesCheckbox.title = String(
            localized: "browser.import.cookies",
            defaultValue: "Cookies (site sign-ins)",
            bundle: .module
        )
        historyCheckbox.title = String(
            localized: "browser.import.history",
            defaultValue: "History (visited pages)",
            bundle: .module
        )
        additionalDataCheckbox.title = String(
            localized: "browser.import.additionalData",
            defaultValue: "Additional data (bookmarks, settings, extensions)",
            bundle: .module
        )
        cookiesCheckbox.target = self
        cookiesCheckbox.action = #selector(handleImportOptionChanged(_:))
        historyCheckbox.target = self
        historyCheckbox.action = #selector(handleImportOptionChanged(_:))
        additionalDataCheckbox.target = self
        additionalDataCheckbox.action = #selector(handleImportOptionChanged(_:))
        cookiesCheckbox.setAccessibilityIdentifier("BrowserImportCookiesCheckbox")
        historyCheckbox.setAccessibilityIdentifier("BrowserImportHistoryCheckbox")
        additionalDataCheckbox.setAccessibilityIdentifier("BrowserImportAdditionalDataCheckbox")
        separateProfilesRadio.title = String(
            localized: "browser.import.destinationMode.separate",
            defaultValue: "Keep profiles separate",
            bundle: .module
        )
        mergeProfilesRadio.title = String(
            localized: "browser.import.destinationMode.merge",
            defaultValue: "Merge all into one cmux profile",
            bundle: .module
        )
        separateProfilesRadio.target = self
        separateProfilesRadio.action = #selector(handleDestinationModeChanged(_:))
        mergeProfilesRadio.target = self
        mergeProfilesRadio.action = #selector(handleDestinationModeChanged(_:))

        destinationModeContainer.orientation = .vertical
        destinationModeContainer.spacing = 6
        destinationModeContainer.alignment = .leading
        destinationModeContainer.addArrangedSubview(separateProfilesRadio)
        destinationModeContainer.addArrangedSubview(mergeProfilesRadio)

        mergeDestinationPopup.target = self
        mergeDestinationPopup.action = #selector(handleMergeDestinationChanged(_:))
        mergeDestinationPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mergeDestinationPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        separateDestinationRows.orientation = .vertical
        separateDestinationRows.spacing = 6
        separateDestinationRows.alignment = .leading

        mergeDestinationRow.orientation = .horizontal
        mergeDestinationRow.spacing = 6
        mergeDestinationRow.alignment = .centerY

        destinationHelpLabel.font = NSFont.systemFont(ofSize: 11)
        destinationHelpLabel.textColor = .secondaryLabelColor
        destinationHelpLabel.maximumNumberOfLines = 2
        destinationHelpLabel.preferredMaxLayoutWidth = 500

        domainField.placeholderString = String(
            localized: "browser.import.domain.placeholder",
            defaultValue: "Optional domains only (e.g. github.com, openai.com)",
            bundle: .module
        )
        domainField.stringValue = ""
        domainField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        domainField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let destinationTitleLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.destination.cmux",
                defaultValue: "cmux destination",
                bundle: .module
            )
        )
        destinationTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let domainLabel = NSTextField(
            labelWithString: String(localized: "browser.import.domain", defaultValue: "Limit to", bundle: .module)
        )
        domainLabel.alignment = .right
        domainLabel.frame.size.width = 72

        let domainRow = NSStackView(views: [domainLabel, domainField])
        domainRow.orientation = .horizontal
        domainRow.spacing = 8
        domainRow.alignment = .centerY
        domainRow.distribution = .fill

        additionalDataNoteLabel.stringValue = String(
            localized: "browser.import.additionalData.note",
            defaultValue: "Bookmarks, settings, and extensions import are not available yet.",
            bundle: .module
        )
        additionalDataNoteLabel.font = NSFont.systemFont(ofSize: 11)
        additionalDataNoteLabel.textColor = .secondaryLabelColor
        additionalDataNoteLabel.maximumNumberOfLines = 2
        additionalDataNoteLabel.preferredMaxLayoutWidth = 500
        additionalDataNoteLabel.isHidden = true

        dataTypesContainer.orientation = .vertical
        dataTypesContainer.spacing = 6
        dataTypesContainer.alignment = .leading
        dataTypesContainer.addArrangedSubview(destinationTitleLabel)
        dataTypesContainer.addArrangedSubview(destinationModeContainer)
        dataTypesContainer.addArrangedSubview(separateDestinationRows)
        dataTypesContainer.addArrangedSubview(mergeDestinationRow)
        dataTypesContainer.addArrangedSubview(destinationHelpLabel)
        dataTypesContainer.addArrangedSubview(cookiesCheckbox)
        dataTypesContainer.addArrangedSubview(historyCheckbox)
        dataTypesContainer.addArrangedSubview(additionalDataCheckbox)
        dataTypesContainer.addArrangedSubview(additionalDataNoteLabel)
        dataTypesContainer.addArrangedSubview(domainRow)
    }

    private func configureInitialState() {
        step = .source
        refreshSourceProfilesList()
        updateAdditionalDataNoteVisibility()
        updateStepUI()
    }

    private func updateStepUI() {
        switch step {
        case .source:
            stepLabel.stringValue = String(
                localized: "browser.import.step.source",
                defaultValue: "Step 1 of 3",
                bundle: .module
            )
            sourceContainer.isHidden = false
            sourceProfilesContainer.isHidden = true
            dataTypesContainer.isHidden = true
            backButton.isHidden = true
            primaryButton.isEnabled = true
            primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next", bundle: .module)
        case .sourceProfiles:
            stepLabel.stringValue = String(
                localized: "browser.import.step.sourceProfiles",
                defaultValue: "Step 2 of 3",
                bundle: .module
            )
            sourceContainer.isHidden = true
            sourceProfilesContainer.isHidden = false
            dataTypesContainer.isHidden = true
            backButton.isHidden = false
            primaryButton.isEnabled = !selectedBrowser().profiles.isEmpty
            primaryButton.title = String(localized: "browser.import.next", defaultValue: "Next", bundle: .module)
        case .dataTypes:
            rebuildStep3DestinationUI()
            stepLabel.stringValue = String(
                localized: "browser.import.step.dataTypes",
                defaultValue: "Step 3 of 3",
                bundle: .module
            )
            sourceContainer.isHidden = true
            sourceProfilesContainer.isHidden = true
            dataTypesContainer.isHidden = false
            backButton.isHidden = false
            primaryButton.isEnabled = true
            primaryButton.title = String(
                localized: "browser.import.start",
                defaultValue: "Start Import",
                bundle: .module
            )
        }
        updatePanelSize()
    }

    private func selectedBrowser() -> InstalledBrowserCandidate {
        let selectedIndex = max(0, min(sourcePopup.indexOfSelectedItem, browsers.count - 1))
        return browsers[selectedIndex]
    }

    private func refreshSourceProfilesList() {
        let browser = selectedBrowser()
        let selectedIDs = storedSelectedSourceProfileIDs(for: browser)

        sourceProfileCheckboxes.removeAll()
        for arrangedSubview in sourceProfilesList.arrangedSubviews {
            sourceProfilesList.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        if browser.profiles.isEmpty {
            sourceProfilesEmptyLabel.stringValue = String(
                format: String(
                    localized: "browser.import.sourceProfiles.empty",
                    defaultValue: "No source profiles detected for %@.",
                    bundle: .module
                ),
                browser.displayName
            )
            sourceProfilesList.addArrangedSubview(sourceProfilesEmptyLabel)
            updateSourceProfilesPresentation(for: browser)
            return
        }

        for profile in browser.profiles {
            let checkbox = NSButton(
                checkboxWithTitle: profile.displayName,
                target: self,
                action: #selector(handleSourceProfileToggled(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(profile.id)
            checkbox.state = selectedIDs.contains(profile.id) ? .on : .off
            checkbox.lineBreakMode = .byTruncatingTail
            sourceProfilesList.addArrangedSubview(checkbox)
            sourceProfileCheckboxes.append(checkbox)
        }

        updateSourceProfilesPresentation(for: browser)
    }

    private func storedSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
        if let existing = selectedSourceProfileIDsByBrowserID[browser.id] {
            return existing
        }
        let defaultSelection = defaultSelectedSourceProfileIDs(for: browser)
        selectedSourceProfileIDsByBrowserID[browser.id] = defaultSelection
        return defaultSelection
    }

    private func defaultSelectedSourceProfileIDs(for browser: InstalledBrowserCandidate) -> Set<String> {
        if let defaultProfile = browser.profiles.first(where: \.isDefault) {
            return [defaultProfile.id]
        }
        if let firstProfile = browser.profiles.first {
            return [firstProfile.id]
        }
        return []
    }

    private func selectedSourceProfiles() -> [InstalledBrowserProfile] {
        let browser = selectedBrowser()
        let selectedIDs = storedSelectedSourceProfileIDs(for: browser)
        return browser.profiles.filter { selectedIDs.contains($0.id) }
    }

    private func resetStep3State() {
        let selectedProfiles = selectedSourceProfiles()
        let defaultPlan = BrowserImportExecutionPlan.defaultPlan(
            selectedSourceProfiles: selectedProfiles,
            destinationProfiles: destinationProfiles,
            preferredSingleDestinationProfileID: initialDestinationProfileID
        )
        destinationMode = defaultPlan.mode
        separateExecutionEntries = BrowserImportExecutionPlan.separateProfilesPlan(
            selectedSourceProfiles: selectedProfiles,
            destinationProfiles: destinationProfiles
        ).entries
        if let initialDestination = defaultPlan.entries.first.flatMap(destinationProfileID(for:)) {
            mergeDestinationProfileID = initialDestination
        } else {
            mergeDestinationProfileID = initialDestinationProfileID
        }
        rebuildStep3DestinationUI()
    }

    private func currentExecutionPlan() -> BrowserImportExecutionPlan {
        let selectedProfiles = selectedSourceProfiles()
        guard !selectedProfiles.isEmpty else {
            return BrowserImportExecutionPlan(mode: .singleDestination, entries: [])
        }

        guard selectedProfiles.count > 1 else {
            return BrowserImportExecutionPlan(
                mode: .singleDestination,
                entries: [
                    BrowserImportExecutionEntry(
                        sourceProfiles: selectedProfiles,
                        destination: .existing(resolvedMergeDestinationProfileID())
                    )
                ]
            )
        }

        switch destinationMode {
        case .separateProfiles:
            let entriesBySourceID = Dictionary(
                uniqueKeysWithValues: separateExecutionEntries.compactMap { entry in
                    entry.sourceProfiles.first.map { ($0.id, entry.destination) }
                }
            )
            let entries = selectedProfiles.map { profile in
                BrowserImportExecutionEntry(
                    sourceProfiles: [profile],
                    destination: entriesBySourceID[profile.id] ?? defaultSeparateDestinationRequest(for: profile)
                )
            }
            return BrowserImportExecutionPlan(mode: .separateProfiles, entries: entries)
        case .singleDestination, .mergeIntoOne:
            return BrowserImportExecutionPlan(
                mode: .mergeIntoOne,
                entries: [
                    BrowserImportExecutionEntry(
                        sourceProfiles: selectedProfiles,
                        destination: .existing(resolvedMergeDestinationProfileID())
                    )
                ]
            )
        }
    }

    private func rebuildStep3DestinationUI() {
        let plan = currentExecutionPlan()
        let presentation = BrowserImportStep3Presentation(plan: plan)
        destinationModeContainer.isHidden = !presentation.showsModeSelector
        separateDestinationRows.isHidden = !presentation.showsSeparateRows
        mergeDestinationRow.isHidden = !presentation.showsSingleDestinationPicker

        if presentation.showsModeSelector {
            separateProfilesRadio.state = destinationMode == .separateProfiles ? .on : .off
            mergeProfilesRadio.state = destinationMode == .mergeIntoOne ? .on : .off
        } else {
            separateProfilesRadio.state = .off
            mergeProfilesRadio.state = .off
        }

        rebuildSeparateDestinationRows(with: plan)
        rebuildMergeDestinationRow()

        if presentation.showsSeparateRows {
            destinationHelpLabel.stringValue = String(
                localized: "browser.import.destinationProfile.separateHelp",
                defaultValue: "Missing cmux profiles are created when import starts.",
                bundle: .module
            )
            destinationHelpLabel.isHidden = false
        } else if plan.entries.count > 1 {
            destinationHelpLabel.stringValue = String(
                localized: "browser.import.destinationProfile.mergeHelp",
                defaultValue: "All selected source profiles will be merged into the chosen cmux browser profile.",
                bundle: .module
            )
            destinationHelpLabel.isHidden = false
        } else {
            destinationHelpLabel.stringValue = ""
            destinationHelpLabel.isHidden = true
        }
    }

    private func rebuildSeparateDestinationRows(with plan: BrowserImportExecutionPlan) {
        separateDestinationOptionsByEntryIndex.removeAll()
        for arrangedSubview in separateDestinationRows.arrangedSubviews {
            separateDestinationRows.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        guard plan.mode == .separateProfiles else { return }

        for (index, entry) in plan.entries.enumerated() {
            guard let sourceProfile = entry.sourceProfiles.first else { continue }
            let sourceLabel = NSTextField(labelWithString: sourceProfile.displayName)
            sourceLabel.alignment = .right
            sourceLabel.frame.size.width = 110

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.target = self
            popup.action = #selector(handleSeparateDestinationChanged(_:))
            popup.tag = index
            popup.setAccessibilityIdentifier(
                "BrowserImportDestinationPopup-\(accessibilitySlug(for: sourceProfile, index: index))"
            )

            let options = destinationOptions(for: entry, sourceProfile: sourceProfile)
            separateDestinationOptionsByEntryIndex[index] = options
            for option in options {
                popup.addItem(withTitle: title(for: option))
            }
            if let selectedIndex = options.firstIndex(of: entry.destination) {
                popup.selectItem(at: selectedIndex)
            } else {
                popup.selectItem(at: 0)
            }
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [sourceLabel, popup])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.distribution = .fill
            separateDestinationRows.addArrangedSubview(row)
        }
    }

    private func rebuildMergeDestinationRow() {
        for arrangedSubview in mergeDestinationRow.arrangedSubviews {
            mergeDestinationRow.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        mergeDestinationPopup.removeAllItems()
        for profile in destinationProfiles {
            mergeDestinationPopup.addItem(withTitle: profile.displayName)
        }
        if let selectedIndex = destinationProfiles.firstIndex(where: { $0.id == resolvedMergeDestinationProfileID() }) {
            mergeDestinationPopup.selectItem(at: selectedIndex)
        } else {
            mergeDestinationPopup.selectItem(at: 0)
            if let firstProfile = destinationProfiles.first {
                mergeDestinationProfileID = firstProfile.id
            }
        }
        mergeDestinationPopup.setAccessibilityIdentifier("BrowserImportDestinationPopup-merge")

        let destinationLabel = NSTextField(
            labelWithString: String(
                localized: "browser.import.destinationProfile",
                defaultValue: "Import into",
                bundle: .module
            )
        )
        destinationLabel.alignment = .right
        destinationLabel.frame.size.width = 110

        mergeDestinationRow.addArrangedSubview(destinationLabel)
        mergeDestinationRow.addArrangedSubview(mergeDestinationPopup)
    }

    private func destinationOptions(
        for entry: BrowserImportExecutionEntry,
        sourceProfile: InstalledBrowserProfile
    ) -> [BrowserImportDestinationRequest] {
        var options = destinationProfiles.map { BrowserImportDestinationRequest.existing($0.id) }
        let createName: String
        switch entry.destination {
        case .createNamed(let name):
            createName = name
        case .existing:
            createName = sourceProfile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !createName.isEmpty,
           !destinationProfiles.contains(where: {
               $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                   .localizedCaseInsensitiveCompare(createName) == .orderedSame
           }) {
            options.append(.createNamed(createName))
        }
        return options
    }

    private func title(for request: BrowserImportDestinationRequest) -> String {
        switch request {
        case .existing(let id):
            return destinationProfiles.first(where: { $0.id == id })?.displayName
                ?? profileResolver.displayName(for: id)
        case .createNamed(let name):
            return String(
                format: String(
                    localized: "browser.import.destinationProfile.create",
                    defaultValue: "Create \"%@\"",
                    bundle: .module
                ),
                name
            )
        }
    }

    private func destinationProfileID(for entry: BrowserImportExecutionEntry) -> UUID? {
        guard case .existing(let id) = entry.destination else { return nil }
        return id
    }

    private func resolvedMergeDestinationProfileID() -> UUID {
        if destinationProfiles.contains(where: { $0.id == mergeDestinationProfileID }) {
            return mergeDestinationProfileID
        }
        return initialDestinationProfileID
    }

    private func defaultSeparateDestinationRequest(
        for profile: InstalledBrowserProfile
    ) -> BrowserImportDestinationRequest {
        BrowserImportExecutionPlan.separateProfilesPlan(
            selectedSourceProfiles: [profile],
            destinationProfiles: destinationProfiles
        ).entries.first?.destination ?? .createNamed(profile.displayName)
    }

    private func accessibilitySlug(for profile: InstalledBrowserProfile, index: Int) -> String {
        let base = profile.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "profile-\(index)" : base
    }

    private func updateSourceProfilesPresentation(for browser: InstalledBrowserCandidate) {
        let presentation = BrowserImportSourceProfilesPresentation(profileCount: browser.profiles.count)
        sourceProfilesScrollHeightConstraint?.constant = presentation.scrollHeight
        sourceProfilesHelpLabel.isHidden = !presentation.showsHelpText
    }

    private func updateAdditionalDataNoteVisibility() {
        additionalDataNoteLabel.isHidden = additionalDataCheckbox.state != .on
    }

    private func updatePanelSize() {
        let contentSize = preferredContentSize()
        let targetFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))

        guard panel.frame.size != targetFrame.size else { return }
        if !panel.isVisible {
            panel.setContentSize(contentSize)
            return
        }

        var frame = panel.frame
        frame.origin.x -= (targetFrame.width - frame.width) / 2
        frame.origin.y -= (targetFrame.height - frame.height) / 2
        frame.size = targetFrame.size
        panel.setFrame(frame, display: true)
    }

    private func preferredContentSize() -> NSSize {
        switch step {
        case .source:
            return NSSize(width: 560, height: 292)
        case .sourceProfiles:
            let presentation = BrowserImportSourceProfilesPresentation(profileCount: selectedBrowser().profiles.count)
            let helpHeight: CGFloat = presentation.showsHelpText ? 24 : 0
            let height = 214 + presentation.scrollHeight + helpHeight
            return NSSize(width: 560, height: min(max(height, 292), 360))
        case .dataTypes:
            var height: CGFloat = currentExecutionPlan().mode == .separateProfiles ? 412 : 374
            if additionalDataCheckbox.state == .on {
                height += 24
            }
            return NSSize(width: 560, height: height)
        }
    }

    private func finishModal(with response: NSApplication.ModalResponse) {
        guard !didFinishModal else { return }
        didFinishModal = true

        if NSApp.modalWindow == panel {
            NSApp.stopModal(withCode: response)
        }
        panel.orderOut(nil)
    }
}
