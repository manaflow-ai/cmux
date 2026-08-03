public import AppKit
import CmuxFoundation
public import CmuxUpdater

/// Native pill control that displays update status and presents update actions.
@MainActor
public final class UpdatePillView: NSView, NSPopoverDelegate {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost
    private var updateAppearance: UpdateAppearance
    private let badgeView = UpdateBadgeView()
    private let textLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let contentStack = NSStackView()
    private var textWidthConstraint: NSLayoutConstraint?
    private var modelObserver: UpdatePresentationObserver?
    private var fontObserver: GlobalFontMagnificationChangeObserver?
    private var popover: NSPopover?
    private var popoverController: UpdatePopoverViewController?
    private var showsPresentation = false

    /// Creates the pill.
    public init(model: UpdateStateModel, accent: NSColor, actions: any UpdateActionsHost) {
        self.model = model
        self.actions = actions
        self.updateAppearance = UpdateAppearance(accent: accent)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupView()

        modelObserver = UpdatePresentationObserver(model: model) { [weak self] in
            self?.applyModel()
        }
        fontObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyModel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: NSSize {
        guard showsPresentation else { return .zero }
        let fitting = contentStack.fittingSize
        return NSSize(width: ceil(fitting.width + 16), height: ceil(max(22, fitting.height + 8)))
    }

    /// Replaces the accent color and refreshes the native presentation.
    public func setAccentColor(_ accent: NSColor) {
        updateAppearance = UpdateAppearance(accent: accent)
        applyModel()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyModel()
    }

    public func popoverDidClose(_ notification: Notification) {
        popover = nil
        popoverController = nil
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(badgeView)
        contentStack.addArrangedSubview(textLabel)
        addSubview(contentStack)

        textLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.title = ""
        actionButton.isBordered = false
        actionButton.imagePosition = .noImage
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(handleTap)
        addSubview(actionButton, positioned: .above, relativeTo: contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            actionButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("UpdatePill")
    }

    private func applyModel() {
        let wasVisible = showsPresentation
        showsPresentation = model.showsPill
        if !showsPresentation {
            closePopover()
        }

        textLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        textLabel.stringValue = model.text
        textLabel.textColor = updateAppearance.foregroundColor(for: model)
        badgeView.update(model: model, appearance: updateAppearance)
        let backgroundColor = updateAppearance.backgroundColor(for: model)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = backgroundColor.usingColorSpace(.deviceRGB)?.cgColor
                ?? NSColor.controlBackgroundColor.cgColor
        }
        toolTip = model.text.isEmpty ? nil : model.text
        setAccessibilityLabel(model.text)

        let width = ceil((model.maxWidthText as NSString).size(withAttributes: [
            .font: textLabel.font ?? GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium),
        ]).width)
        textWidthConstraint?.isActive = false
        let constraint = textLabel.widthAnchor.constraint(equalToConstant: width)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        textWidthConstraint = constraint

        alphaValue = showsPresentation ? 1 : 0
        actionButton.isEnabled = showsPresentation
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
        if wasVisible != showsPresentation {
            needsLayout = true
        }
    }

    @objc private func handleTap() {
        if model.showsDetectedBackgroundUpdate {
            if model.hasCachedDetectedUpdateDetails {
                togglePopover()
            } else if popover?.isShown == true {
                closePopover()
            } else {
                showPopover()
                actions.checkForUpdatesInCustomUI()
            }
            return
        }

        if case .notFound(let notFound) = model.state {
            model.setState(.idle)
            notFound.acknowledgement()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard window != nil else { return }
        let controller = UpdatePopoverViewController(model: model, actions: actions) { [weak self] in
            self?.closePopover()
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = controller
        popover.delegate = self
        controller.preferredSizeDidChange = { [weak popover] size in
            guard let popover else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                popover.contentSize = size
            }
        }
        popover.contentSize = controller.preferredContentSize
        self.popover = popover
        popoverController = controller
        layoutSubtreeIfNeeded()
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }
}

/// Native menu item that appears while the current update phase is installable.
@MainActor
public final class InstallUpdateMenuItem: NSMenuItem {
    private let model: UpdateStateModel
    private let actions: any UpdateActionsHost
    private var modelObserver: UpdatePresentationObserver?

    /// Creates the update menu item.
    public init(model: UpdateStateModel, actions: any UpdateActionsHost) {
        self.model = model
        self.actions = actions
        super.init(
            title: String(
                localized: "update.installAndRelaunch",
                defaultValue: "Install Update and Relaunch"
            ),
            action: nil,
            keyEquivalent: ""
        )
        target = self
        action = #selector(attemptUpdate)
        modelObserver = UpdatePresentationObserver(model: model) { [weak self] in
            self?.isHidden = !(self?.model.state.isInstallable ?? false)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func attemptUpdate() {
        actions.attemptUpdate()
    }
}
