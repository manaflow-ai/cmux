import AppKit

private final class PaddedToolbarContentView: NSView {
    private let contentView: NSView
    private let insets: NSEdgeInsets

    init(contentView: NSView, insets: NSEdgeInsets) {
        self.contentView = contentView
        self.insets = insets
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentView.fittingSize
        return NSSize(
            width: contentSize.width + insets.left + insets.right,
            height: contentSize.height + insets.top + insets.bottom
        )
    }
}

private final class CapsuleToolbarBackgroundView: NSView {
    private let contentView: NSView
    private let insets: NSEdgeInsets
    private let gradientLayer = CAGradientLayer()

    init(contentView: NSView, insets: NSEdgeInsets) {
        self.contentView = contentView
        self.insets = insets
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor
        layer?.borderWidth = 1

        gradientLayer.colors = [
            NSColor(calibratedRed: 0.25, green: 0.22, blue: 0.18, alpha: 0.96).cgColor,
            NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.20, alpha: 0.96).cgColor,
            NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96).cgColor,
        ]
        gradientLayer.locations = [0.0, 0.45, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.masksToBounds = true
        layer?.insertSublayer(gradientLayer, at: 0)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = radius
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentView.fittingSize
        return NSSize(
            width: contentSize.width + insets.left + insets.right,
            height: contentSize.height + insets.top + insets.bottom
        )
    }
}

@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let commandPaletteHintItemIdentifier = NSToolbarItem.Identifier("cmux.commandPaletteHint")

    private struct CommandPaletteHintViews {
        let iconView: NSImageView
        let textField: NSTextField
    }

    private var commandPaletteHintViews: [ObjectIdentifier: CommandPaletteHintViews] = [:]
    private var observers: [NSObjectProtocol] = []
    private var minuteTimer: Timer?
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        minuteTimer?.invalidate()
    }

    func start() {
        attachToExistingWindows()
        installObservers()
        startMinuteTimer()
        updateCommandPaletteHint()
    }

    func attach(to window: NSWindow) {
        attachToolbarIfNeeded(to: window)
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                self?.attachToolbarIfNeeded(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                self?.attachToolbarIfNeeded(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateToolbarVisibilityIfNeeded()
                self?.updateCommandPaletteHint()
            }
        })

        observers.append(center.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCommandPaletteHint()
            }
        })
    }

    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCommandPaletteHint()
            }
        }
        minuteTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateToolbarVisibilityIfNeeded() {
        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode

        let isMinimal = currentMode == .minimal
        for window in NSApp.windows where shouldManageToolbar(for: window) {
            if isMinimal {
                window.toolbar = nil
            } else {
                attachToolbarIfNeeded(to: window)
            }
        }

        if !isMinimal {
            DispatchQueue.main.async {
                for window in NSApp.windows where self.shouldManageToolbar(for: window) {
                    for accessory in window.titlebarAccessoryViewControllers where !accessory.isHidden {
                        accessory.view.needsLayout = true
                        accessory.view.superview?.needsLayout = true
                    }
                    window.contentView?.needsLayout = true
                    window.contentView?.superview?.needsLayout = true
                    window.invalidateShadow()
                }
            }
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attachToolbarIfNeeded(to: window)
        }
    }

    private func shouldManageToolbar(for window: NSWindow) -> Bool {
        if let rawIdentifier = window.identifier?.rawValue {
            return rawIdentifier == "cmux.main" || rawIdentifier.hasPrefix("cmux.main.")
        }

        // During early startup the main window identifier may not be set yet.
        // Main workspace windows use an empty title, while utility windows have titles.
        return window.title.isEmpty
    }

    private func attachToolbarIfNeeded(to window: NSWindow) {
        guard shouldManageToolbar(for: window) else { return }
        guard window.toolbar == nil else { return }
        guard !WorkspacePresentationModeSettings.isMinimal() else { return }

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cmux.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
    }

    private func updateCommandPaletteHint() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let style = timeStyle(for: hour)

        let fullText = now.formatted(date: .omitted, time: .shortened)

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let symbolImage = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)

        for views in commandPaletteHintViews.values {
            if views.textField.stringValue != fullText {
                views.textField.stringValue = fullText
            }
            views.iconView.image = symbolImage
            views.iconView.contentTintColor = style.color
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandPaletteHintItemIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, commandPaletteHintItemIdentifier, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == commandPaletteHintItemIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.clear.cgColor
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let paddedView = PaddedToolbarContentView(
            contentView: stack,
            insets: NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        )
        paddedView.setContentHuggingPriority(.required, for: .horizontal)
        paddedView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let capsuleView = CapsuleToolbarBackgroundView(
            contentView: paddedView,
            insets: NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        )
        capsuleView.setContentHuggingPriority(.required, for: .horizontal)
        capsuleView.setContentCompressionResistancePriority(.required, for: .horizontal)

        item.view = capsuleView

        commandPaletteHintViews[ObjectIdentifier(toolbar)] = CommandPaletteHintViews(
            iconView: iconView,
            textField: label
        )
        updateCommandPaletteHint()
        return item
    }

    private struct TimeStyle {
        let symbolName: String
        let color: NSColor
    }

    private func timeStyle(for hour: Int) -> TimeStyle {
        switch hour {
        case 6..<12:
            return TimeStyle(symbolName: "sunrise.fill", color: .systemOrange)
        case 12..<17:
            return TimeStyle(symbolName: "sun.max.fill", color: .systemYellow)
        case 17..<21:
            return TimeStyle(symbolName: "sunset.fill", color: .systemPink)
        default:
            return TimeStyle(symbolName: "moon.stars.fill", color: .systemIndigo)
        }
    }
}
