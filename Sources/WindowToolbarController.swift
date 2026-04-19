import AppKit
import Combine
import SwiftUI

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
        layer?.borderWidth = 1

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

        updateGradientColors()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGradientColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGradientColors()
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = contentView.fittingSize
        return NSSize(
            width: contentSize.width + insets.left + insets.right,
            height: contentSize.height + insets.top + insets.bottom
        )
    }

    private func updateGradientColors() {
        let isDarkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            gradientLayer.colors = [
                NSColor(calibratedRed: 0.25, green: 0.22, blue: 0.18, alpha: 0.96).cgColor,
                NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.20, alpha: 0.96).cgColor,
                NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 0.96).cgColor,
            ]
            layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor
        } else {
            gradientLayer.colors = [
                NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 0.97).cgColor,
                NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.96, alpha: 0.97).cgColor,
                NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.95, alpha: 0.97).cgColor,
            ]
            layer?.borderColor = NSColor(calibratedWhite: 0.0, alpha: 0.12).cgColor
        }
    }
}

@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let commandItemIdentifier = NSToolbarItem.Identifier("cmux.focusedCommand")
    private let timeIndicatorItemIdentifier = NSToolbarItem.Identifier("cmux.timeIndicator")

    private struct TimeIndicatorViews {
        let iconView: NSImageView
        let textField: NSTextField
    }

    private var commandLabels: [ObjectIdentifier: NSTextField] = [:]
    private var timeIndicatorViews: [ObjectIdentifier: TimeIndicatorViews] = [:]
    private var observers: [NSObjectProtocol] = []
    private let focusedCommandUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    private var minuteTimer: Timer?
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()
    private var lastKnownTimeIndicatorEnabled = TitlebarTimeIndicatorSettings.isEnabled()

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
        scheduleFocusedCommandTextUpdate()
        updateTimeIndicator()
    }

    func attach(to window: NSWindow) {
        attachToolbarIfNeeded(to: window)
    }

    private func installObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidFocusTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

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
                self?.updateToolbarConfigurationIfNeeded()
            }
        })
    }

    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimeIndicator()
            }
        }
        minuteTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateToolbarConfigurationIfNeeded() {
        let currentMode = WorkspacePresentationModeSettings.mode()
        let currentTimeIndicatorEnabled = TitlebarTimeIndicatorSettings.isEnabled()
        let modeChanged = currentMode != lastKnownPresentationMode
        let timeIndicatorChanged = currentTimeIndicatorEnabled != lastKnownTimeIndicatorEnabled

        guard modeChanged || timeIndicatorChanged else {
            pruneStaleViewCaches()
            return
        }

        lastKnownPresentationMode = currentMode
        lastKnownTimeIndicatorEnabled = currentTimeIndicatorEnabled

        let isMinimal = currentMode == .minimal
        for window in NSApp.windows where shouldManageToolbar(for: window) {
            if isMinimal {
                clearToolbar(for: window)
            } else if timeIndicatorChanged {
                clearToolbar(for: window)
                attachToolbarIfNeeded(to: window)
            } else {
                attachToolbarIfNeeded(to: window)
            }
        }

        // After toolbar changes, force titlebar accessories to recalculate.
        // Toolbar removal/re-addition changes the titlebar geometry, and
        // accessories hidden via isHidden need a layout pass to reappear.
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

        pruneStaleViewCaches()
        scheduleFocusedCommandTextUpdate()
        updateTimeIndicator()
    }

    private func clearToolbar(for window: NSWindow) {
        if let toolbar = window.toolbar {
            let key = ObjectIdentifier(toolbar)
            commandLabels.removeValue(forKey: key)
            timeIndicatorViews.removeValue(forKey: key)
        }
        window.toolbar = nil
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attachToolbarIfNeeded(to: window)
        }
    }

    private func shouldManageToolbar(for window: NSWindow) -> Bool {
        guard let rawIdentifier = window.identifier?.rawValue else { return false }
        return rawIdentifier == "cmux.main" || rawIdentifier.hasPrefix("cmux.main.")
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

    private func scheduleFocusedCommandTextUpdate() {
        focusedCommandUpdateCoalescer.signal { [weak self] in
            self?.updateFocusedCommandText()
        }
    }

    private func pruneStaleViewCaches() {
        let activeToolbars = Set(NSApp.windows.compactMap { $0.toolbar }.map(ObjectIdentifier.init))
        commandLabels = commandLabels.filter { activeToolbars.contains($0.key) }
        timeIndicatorViews = timeIndicatorViews.filter { activeToolbars.contains($0.key) }
    }

    private func updateFocusedCommandText() {
        pruneStaleViewCaches()

        let text: String
        if let tabManager = AppDelegate.shared?.tabManager,
           let selectedId = tabManager.selectedTabId,
           let tab = tabManager.tabs.first(where: { $0.id == selectedId }) {
            let title = tab.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            text = title.isEmpty ? "Cmd: —" : "Cmd: \(title)"
        } else {
            text = "Cmd: —"
        }

        for label in commandLabels.values where label.stringValue != text {
            label.stringValue = text
        }
    }

    private func updateTimeIndicator() {
        pruneStaleViewCaches()
        guard TitlebarTimeIndicatorSettings.isEnabled() else { return }

        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let style = timeStyle(for: hour)
        let fullText = now.formatted(date: .omitted, time: .shortened)
        let iconDescription = String(
            localized: "titlebar.timeIndicator.icon.accessibility",
            defaultValue: "Time of day"
        )

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let symbolImage = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: iconDescription)?
            .withSymbolConfiguration(symbolConfiguration)

        for views in timeIndicatorViews.values {
            if views.textField.stringValue != fullText {
                views.textField.stringValue = fullText
            }
            views.iconView.image = symbolImage
            views.iconView.contentTintColor = style.color
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, timeIndicatorItemIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if TitlebarTimeIndicatorSettings.isEnabled() {
            return [.flexibleSpace, timeIndicatorItemIdentifier, .flexibleSpace]
        }
        return [commandItemIdentifier, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == commandItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "titlebar.focusedCommand.label", defaultValue: "Focused Command")
            item.paletteLabel = item.label
            item.toolTip = String(
                localized: "titlebar.focusedCommand.tooltip",
                defaultValue: "Focused command in the active workspace"
            )

            let label = NSTextField(labelWithString: "Cmd: —")
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setAccessibilityLabel(item.label)
            item.view = label

            commandLabels[ObjectIdentifier(toolbar)] = label
            scheduleFocusedCommandTextUpdate()
            return item
        }

        if itemIdentifier == timeIndicatorItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "titlebar.timeIndicator.label", defaultValue: "Current Time")
            item.paletteLabel = item.label
            item.toolTip = String(localized: "titlebar.timeIndicator.tooltip", defaultValue: "Current local time")

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
            capsuleView.setAccessibilityLabel(item.label)

            item.view = capsuleView

            timeIndicatorViews[ObjectIdentifier(toolbar)] = TimeIndicatorViews(
                iconView: iconView,
                textField: label
            )
            updateTimeIndicator()
            return item
        }

        return nil
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
