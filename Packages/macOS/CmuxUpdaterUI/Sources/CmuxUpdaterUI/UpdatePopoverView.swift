public import AppKit
import CmuxFoundation
public import CmuxUpdater
@preconcurrency import Sparkle

/// Native popover controller that displays detailed update information and actions.
@MainActor
public final class UpdatePopoverViewController: NSViewController {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost
    private let dismissHandler: @MainActor () -> Void
    private var modelObserver: UpdatePresentationObserver?
    private var fontObserver: GlobalFontMagnificationChangeObserver?

    /// Called after the native content's fitting size changes.
    public var preferredSizeDidChange: (@MainActor (NSSize) -> Void)?

    /// Creates the popover controller.
    public init(
        model: UpdateStateModel,
        actions: any UpdateActionsHost,
        dismiss: @MainActor @escaping () -> Void = {}
    ) {
        self.model = model
        self.actions = actions
        self.dismissHandler = dismiss
        super.init(nibName: nil, bundle: nil)

        modelObserver = UpdatePresentationObserver(model: model) { [weak self] in
            self?.render()
        }
        fontObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        view = NSView()
    }

    private func render() {
        let content: NSView
        switch model.effectiveState {
        case .idle:
            if model.showsDetectedBackgroundUpdate, let item = model.detectedUpdateItem {
                content = makeDetectedUpdateView(item: item)
            } else if model.showsDetectedBackgroundUpdate, let version = model.detectedUpdateVersion {
                content = makeDetectedUpdatePendingView(version: version)
            } else {
                content = NSView()
            }
        case .permissionRequest:
            content = makePermissionRequestView()
        case .preparingCheck:
            content = makeCheckingView(
                title: String(localized: "update.preparingCheck", defaultValue: "Preparing Update Check…")
            )
        case .checking:
            content = makeCheckingView(
                title: String(localized: "update.popover.checking", defaultValue: "Checking for updates…")
            )
        case .updateAvailable(let update):
            content = makeUpdateAvailableView(update: update)
        case .startingDownload:
            content = makeLoadingView(
                title: String(localized: "update.startingDownload", defaultValue: "Starting Download…")
            )
        case .downloading(let download):
            content = makeDownloadingView(download: download)
        case .extracting(let extracting):
            content = makeExtractingView(extracting: extracting)
        case .installing:
            content = makeInstallingView()
        case .notFound:
            content = makeNotFoundView()
        case .error(let error):
            content = makeErrorView(error: error)
        }

        view = content
        view.layoutSubtreeIfNeeded()
        let fittingSize = view.fittingSize
        let size = NSSize(width: 300, height: ceil(max(1, fittingSize.height)))
        preferredContentSize = size
        preferredSizeDidChange?(size)
    }

    private func makeDetectedUpdateView(item: SUAppcastItem) -> NSView {
        let body = verticalStack(spacing: 12)
        body.addArrangedSubview(titleLabel(
            String(localized: "update.popover.updateAvailable", defaultValue: "Update Available")
        ))
        body.addArrangedSubview(makeMetadataView(item: item))
        body.addArrangedSubview(buttonRow([
            UpdateActionButton(
                title: String(localized: "common.later", defaultValue: "Later"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in self?.dismiss() },
            spacer(),
            primaryButton(
                String(localized: "common.installAndRelaunch", defaultValue: "Install and Relaunch")
            ) { [weak self] in
                guard let self else { return }
                self.actions.attemptUpdate()
                self.dismiss()
            },
        ]))
        return makePaddedRoot(body, releaseNotes: UpdateState.ReleaseNotes(
            displayVersionString: item.displayVersionString
        ))
    }

    private func makeDetectedUpdatePendingView(version: String) -> NSView {
        let body = verticalStack(spacing: 16)
        body.addArrangedSubview(titleLabel(
            String(localized: "update.popover.updateAvailable", defaultValue: "Update Available")
        ))
        body.addArrangedSubview(metadataRow(
            label: String(localized: "update.popover.version", defaultValue: "Version:"),
            value: version
        ))
        body.addArrangedSubview(loadingRow(
            String(localized: "update.popover.checking", defaultValue: "Checking for updates…")
        ))
        return makePaddedRoot(body)
    }

    private func makePermissionRequestView() -> NSView {
        let body = verticalStack(spacing: 16)
        let copy = verticalStack(spacing: 8)
        copy.addArrangedSubview(titleLabel(
            String(localized: "update.popover.enableAutoUpdates", defaultValue: "Enable automatic updates?")
        ))
        copy.addArrangedSubview(bodyLabel(
            String(
                localized: "update.popover.autoUpdatesDescription",
                defaultValue: "cmux can automatically check for updates in the background."
            )
        ))
        body.addArrangedSubview(copy)
        body.addArrangedSubview(buttonRow([
            UpdateActionButton(
                title: String(localized: "common.notNow", defaultValue: "Not Now"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in self?.answerPermission(automaticChecks: false) },
            spacer(),
            primaryButton(String(localized: "common.allow", defaultValue: "Allow")) { [weak self] in
                self?.answerPermission(automaticChecks: true)
            },
        ]))
        return makePaddedRoot(body)
    }

    private func makeCheckingView(title: String) -> NSView {
        let body = verticalStack(spacing: 16)
        body.addArrangedSubview(loadingRow(title))
        body.addArrangedSubview(buttonRow([
            spacer(),
            UpdateActionButton(
                title: String(localized: "common.cancel", defaultValue: "Cancel"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in self?.cancelCheck() },
        ]))
        return makePaddedRoot(body)
    }

    private func makeUpdateAvailableView(update: UpdateState.UpdateAvailable) -> NSView {
        let body = verticalStack(spacing: 12)
        body.addArrangedSubview(titleLabel(
            String(localized: "update.popover.updateAvailable", defaultValue: "Update Available")
        ))
        body.addArrangedSubview(makeMetadataView(item: update.appcastItem))
        body.addArrangedSubview(buttonRow([
            UpdateActionButton(title: String(localized: "common.skip", defaultValue: "Skip")) { [weak self] in
                self?.answerAvailableUpdate(.skip)
            },
            UpdateActionButton(
                title: String(localized: "common.later", defaultValue: "Later"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in
                self?.answerAvailableUpdate(.dismiss)
            },
            spacer(),
            primaryButton(
                String(localized: "common.installAndRelaunch", defaultValue: "Install and Relaunch")
            ) { [weak self] in
                guard let self else { return }
                self.actions.attemptUpdate()
                self.dismiss()
            },
        ]))
        return makePaddedRoot(body, releaseNotes: update.releaseNotes)
    }

    private func makeLoadingView(title: String) -> NSView {
        makePaddedRoot(loadingRow(title))
    }

    private func makeDownloadingView(download: UpdateState.Downloading) -> NSView {
        let body = verticalStack(spacing: 16)
        let status = verticalStack(spacing: 8)
        status.addArrangedSubview(titleLabel(
            String(localized: "update.popover.downloadingUpdate", defaultValue: "Downloading Update")
        ))
        status.addArrangedSubview(progressView(
            value: download.expectedLength.flatMap { $0 > 0 ? Double(download.progress) / Double($0) : nil }
        ))
        body.addArrangedSubview(status)
        body.addArrangedSubview(buttonRow([
            spacer(),
            UpdateActionButton(
                title: String(localized: "common.cancel", defaultValue: "Cancel"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in self?.cancelDownload() },
        ]))
        return makePaddedRoot(body)
    }

    private func makeExtractingView(extracting: UpdateState.Extracting) -> NSView {
        let body = verticalStack(spacing: 8)
        body.addArrangedSubview(titleLabel(
            String(localized: "update.popover.preparingUpdate", defaultValue: "Preparing Update")
        ))
        body.addArrangedSubview(progressView(value: extracting.progress))
        return makePaddedRoot(body)
    }

    private func makeInstallingView() -> NSView {
        let body = verticalStack(spacing: 16)
        let copy = verticalStack(spacing: 8)
        copy.addArrangedSubview(titleLabel(
            String(localized: "update.popover.restartRequired", defaultValue: "Restart Required")
        ))
        copy.addArrangedSubview(bodyLabel(String(
            localized: "update.popover.restartRequired.message",
            defaultValue: "The update is ready. Please restart the application to complete the installation."
        )))
        body.addArrangedSubview(copy)
        body.addArrangedSubview(buttonRow([
            UpdateActionButton(
                title: String(localized: "common.restartLater", defaultValue: "Restart Later"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in self?.dismissInstall() },
            spacer(),
            primaryButton(String(localized: "common.restartNow", defaultValue: "Restart Now")) { [weak self] in
                self?.restartNow()
            },
        ]))
        return makePaddedRoot(body)
    }

    private func makeNotFoundView() -> NSView {
        let body = verticalStack(spacing: 16)
        let copy = verticalStack(spacing: 8)
        copy.addArrangedSubview(titleLabel(
            String(localized: "update.popover.noUpdatesFound", defaultValue: "No Updates Found")
        ))
        copy.addArrangedSubview(bodyLabel(String(
            localized: "update.popover.noUpdatesFound.message",
            defaultValue: "You're already running the latest version."
        )))
        body.addArrangedSubview(copy)
        body.addArrangedSubview(buttonRow([
            spacer(),
            primaryButton(String(localized: "common.ok", defaultValue: "OK")) { [weak self] in
                self?.acknowledgeNotFound()
            },
        ]))
        return makePaddedRoot(body)
    }

    private func makeErrorView(error: UpdateState.Error) -> NSView {
        let title = UpdateStateModel.userFacingErrorTitle(for: error.error)
        let message = UpdateStateModel.userFacingErrorMessage(for: error.error)
        let downloadURL = UpdateManualDownloadRecovery().url(
            for: error.error,
            feedURLString: error.feedURLString
        )
        let details = UpdateErrorDetailsFormatter().details(
            for: error.error,
            technicalDetails: error.technicalDetails,
            feedURLString: error.feedURLString,
            logPath: actions.updateLogPath
        )

        let body = verticalStack(spacing: 16)
        let copy = verticalStack(spacing: 8)
        let heading = horizontalStack(spacing: 8)
        let image = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        image.contentTintColor = .systemOrange
        heading.addArrangedSubview(image)
        heading.addArrangedSubview(titleLabel(title))
        copy.addArrangedSubview(heading)
        copy.addArrangedSubview(bodyLabel(message))
        body.addArrangedSubview(copy)

        if let downloadURL {
            let download = primaryButton(String(
                localized: "update.error.downloadLatest.button",
                defaultValue: "Download Latest Version"
            )) {
                NSWorkspace.shared.open(downloadURL)
            }
            body.addArrangedSubview(download)
        }

        body.addArrangedSubview(detailsView(details))
        body.addArrangedSubview(buttonRow([
            UpdateActionButton(title: String(localized: "common.copyDetails", defaultValue: "Copy Details")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(details, forType: .string)
            },
            UpdateActionButton(
                title: String(localized: "common.ok", defaultValue: "OK"),
                keyEquivalent: "\u{1b}"
            ) { [weak self] in self?.dismissError() },
            spacer(),
            primaryButton(String(localized: "common.retry", defaultValue: "Retry")) { [weak self] in
                self?.retryError()
            },
        ]))
        return makePaddedRoot(body)
    }

    private func makeMetadataView(item: SUAppcastItem) -> NSView {
        let stack = verticalStack(spacing: 4)
        stack.addArrangedSubview(metadataRow(
            label: String(localized: "update.popover.version", defaultValue: "Version:"),
            value: item.displayVersionString
        ))
        if item.contentLength > 0 {
            stack.addArrangedSubview(metadataRow(
                label: String(localized: "update.popover.size", defaultValue: "Size:"),
                value: ByteCountFormatter.string(fromByteCount: Int64(item.contentLength), countStyle: .file)
            ))
        }
        if let date = item.date {
            stack.addArrangedSubview(metadataRow(
                label: String(localized: "update.popover.released", defaultValue: "Released:"),
                value: date.formatted(date: .abbreviated, time: .omitted)
            ))
        }
        return stack
    }

    private func makePaddedRoot(_ content: NSView, releaseNotes: UpdateState.ReleaseNotes? = nil) -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let outer = verticalStack(spacing: 0)
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let padding = NSView()
        padding.translatesAutoresizingMaskIntoConstraints = false
        padding.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: padding.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: padding.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: padding.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: padding.bottomAnchor, constant: -16),
        ])
        outer.addArrangedSubview(padding)

        if let releaseNotes {
            outer.addArrangedSubview(separator())
            let link = UpdateActionButton(title: releaseNotes.label, bezelStyle: .inline) {
                NSWorkspace.shared.open(releaseNotes.url)
            }
            link.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            link.imagePosition = .imageLeading
            link.alignment = .left
            link.contentTintColor = .labelColor
            let linkHost = NSView()
            linkHost.translatesAutoresizingMaskIntoConstraints = false
            linkHost.addSubview(link)
            NSLayoutConstraint.activate([
                link.leadingAnchor.constraint(equalTo: linkHost.leadingAnchor, constant: 12),
                link.trailingAnchor.constraint(equalTo: linkHost.trailingAnchor, constant: -12),
                link.topAnchor.constraint(equalTo: linkHost.topAnchor, constant: 8),
                link.bottomAnchor.constraint(equalTo: linkHost.bottomAnchor, constant: -8),
            ])
            outer.addArrangedSubview(linkHost)
        }
        return root
    }

    private func metadataRow(label: String, value: String) -> NSView {
        let row = horizontalStack(spacing: 6)
        let labelView = bodyLabel(label)
        labelView.textColor = .secondaryLabelColor
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 60).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(bodyLabel(value))
        row.addArrangedSubview(spacer())
        return row
    }

    private func loadingRow(_ title: String) -> NSView {
        let row = horizontalStack(spacing: 10)
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        row.addArrangedSubview(progress)
        row.addArrangedSubview(label(title, font: GlobalFontMagnification.systemFont(ofSize: 13)))
        row.addArrangedSubview(spacer())
        return row
    }

    private func progressView(value: Double?) -> NSView {
        let stack = verticalStack(spacing: 6)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = value == nil
        progress.minValue = 0
        progress.maxValue = 1
        if let value {
            let clamped = min(1, max(0, value))
            progress.doubleValue = clamped
            stack.addArrangedSubview(progress)
            let percent = bodyLabel(String(format: "%.0f%%", clamped * 100))
            percent.textColor = .secondaryLabelColor
            stack.addArrangedSubview(percent)
        } else {
            progress.startAnimation(nil)
            stack.addArrangedSubview(progress)
        }
        return stack
    }

    private func detailsView(_ details: String) -> NSView {
        let stack = verticalStack(spacing: 6)
        stack.addArrangedSubview(label(
            String(localized: "update.popover.details", defaultValue: "Details"),
            font: GlobalFontMagnification.systemFont(ofSize: 11, weight: .semibold)
        ))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 10)
        text.textColor = .secondaryLabelColor
        text.string = details
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(scroll)
        return stack
    }

    private func titleLabel(_ text: String) -> NSTextField {
        label(text, font: GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold))
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let view = label(text, font: GlobalFontMagnification.systemFont(ofSize: 11))
        view.textColor = .secondaryLabelColor
        return view
    }

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func primaryButton(_ title: String, handler: @MainActor @escaping () -> Void) -> UpdateActionButton {
        let button = UpdateActionButton(title: title, keyEquivalent: "\r", handler: handler)
        button.bezelColor = .controlAccentColor
        return button
    }

    private func buttonRow(_ views: [NSView]) -> NSStackView {
        let row = horizontalStack(spacing: 8)
        views.forEach(row.addArrangedSubview)
        return row
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func dismiss() {
        dismissHandler()
    }

    private func answerPermission(automaticChecks: Bool) {
        guard case .permissionRequest(let request) = model.effectiveState else { return }
        request.reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: automaticChecks,
            sendSystemProfile: false
        ))
        dismiss()
    }

    private func cancelCheck() {
        switch model.effectiveState {
        case .preparingCheck(let checking), .checking(let checking):
            checking.cancel()
            dismiss()
        default:
            return
        }
    }

    private func answerAvailableUpdate(_ choice: SPUUserUpdateChoice) {
        guard case .updateAvailable(let update) = model.effectiveState else { return }
        update.reply(choice)
        dismiss()
    }

    private func cancelDownload() {
        guard case .downloading(let download) = model.effectiveState else { return }
        download.cancel()
        dismiss()
    }

    private func dismissInstall() {
        guard case .installing(let installing) = model.effectiveState else { return }
        installing.dismiss()
        dismiss()
    }

    private func restartNow() {
        guard case .installing(let installing) = model.effectiveState else { return }
        installing.retryTerminatingApplication()
        dismiss()
    }

    private func acknowledgeNotFound() {
        guard case .notFound(let notFound) = model.effectiveState else { return }
        notFound.acknowledgement()
        dismiss()
    }

    private func dismissError() {
        guard case .error(let error) = model.effectiveState else { return }
        error.dismiss()
        dismiss()
    }

    private func retryError() {
        guard case .error(let error) = model.effectiveState else { return }
        error.retry()
        dismiss()
    }
}
