import AppKit
import CmuxAppKitSupportUI
import CmuxSettings

@MainActor
private final class NativeClosureTarget: NSObject {
    private let handler: (Any?) -> Void

    init(_ handler: @escaping (Any?) -> Void) {
        self.handler = handler
    }

    @objc
    func invoke(_ sender: Any?) {
        handler(sender)
    }
}

private final class NativeFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class NativeFormViewController: NSViewController {
    private let contentStack = NSStackView()
    private var targets: [NativeClosureTarget] = []

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let documentView = NativeFlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        view = scrollView
    }

    func addHeading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        addArranged(label)
    }

    func addSection(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addArranged(label, topSpacing: 7)
    }

    @discardableResult
    func addNote(_ text: String, selectable: Bool = false) -> NSTextField {
        let label = selectable ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        if selectable {
            label.isSelectable = true
        }
        addArranged(label)
        return label
    }

    func addSeparator() {
        let separator = NSBox()
        separator.boxType = .separator
        addArranged(separator, topSpacing: 4)
    }

    @discardableResult
    func addButton(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        bind(button) { _ in action() }
        addArranged(button)
        return button
    }

    @discardableResult
    func addCheckbox(
        _ title: String,
        value: Bool,
        action: @escaping (Bool) -> Void
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off
        bind(button) { sender in
            guard let sender = sender as? NSButton else { return }
            action(sender.state == .on)
        }
        addArranged(button)
        return button
    }

    @discardableResult
    func addPopup(
        _ title: String,
        options: [(title: String, value: String)],
        selectedValue: String,
        action: @escaping (String) -> Void
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }
        if let selected = popup.itemArray.first(where: {
            ($0.representedObject as? String) == selectedValue
        }) {
            popup.select(selected)
        }
        bind(popup) { sender in
            guard let sender = sender as? NSPopUpButton,
                  let value = sender.selectedItem?.representedObject as? String else { return }
            action(value)
        }
        addArranged(labeledRow(title, control: popup))
        return popup
    }

    @discardableResult
    func addSlider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        format: String = "%.1f",
        action: @escaping (Double) -> Void
    ) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: nil,
            action: nil
        )
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let valueLabel = NSTextField(labelWithString: String(format: format, value))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true

        bind(slider) { sender in
            guard let sender = sender as? NSSlider else { return }
            valueLabel.stringValue = String(format: format, sender.doubleValue)
            action(sender.doubleValue)
        }

        let row = labeledRow(title, controls: [slider, valueLabel])
        addArranged(row)
        return slider
    }

    @discardableResult
    func addTextField(
        _ title: String,
        value: String,
        action: @escaping (String) -> Void
    ) -> NSTextField {
        let field = NSTextField(string: value)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        bind(field) { sender in
            guard let sender = sender as? NSTextField else { return }
            action(sender.stringValue)
        }
        addArranged(labeledRow(title, control: field))
        return field
    }

    @discardableResult
    func addColorWell(
        _ title: String,
        color: NSColor,
        action: @escaping (NSColor) -> Void
    ) -> NSColorWell {
        let colorWell = NSColorWell()
        colorWell.color = color
        bind(colorWell) { sender in
            guard let sender = sender as? NSColorWell else { return }
            action(sender.color)
        }
        addArranged(labeledRow(title, control: colorWell))
        return colorWell
    }

    func addCustomView(_ customView: NSView) {
        addArranged(customView)
    }

    private func addArranged(_ arrangedView: NSView, topSpacing: CGFloat = 0) {
        _ = view
        arrangedView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(arrangedView)
        arrangedView.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor).isActive = true
        if topSpacing > 0 {
            contentStack.setCustomSpacing(topSpacing, after: contentStack.arrangedSubviews.dropLast().last ?? arrangedView)
        }
    }

    private func labeledRow(_ title: String, control: NSView) -> NSStackView {
        labeledRow(title, controls: [control])
    }

    private func labeledRow(_ title: String, controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [label] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func bind(_ control: NSControl, handler: @escaping (Any?) -> Void) {
        let target = NativeClosureTarget(handler)
        targets.append(target)
        control.target = target
        control.action = #selector(NativeClosureTarget.invoke(_:))
    }
}

@MainActor
private func makeNativePanel(
    title: String,
    identifier: String,
    size: NSSize,
    resizable: Bool = false,
    fullSizeContent: Bool = false,
    contentViewController: NSViewController
) -> NSPanel {
    var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow]
    if resizable { style.insert(.resizable) }
    if fullSizeContent { style.insert(.fullSizeContentView) }
    let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: style,
        backing: .buffered,
        defer: false
    )
    panel.title = title
    panel.identifier = NSUserInterfaceItemIdentifier(identifier)
    panel.isMovableByWindowBackground = true
    panel.contentViewController = contentViewController
    panel.center()
    AppDelegate.shared?.applyWindowDecorations(to: panel)
    return panel
}

@MainActor
private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

@MainActor
private func nativeDebugForm(_ title: String) -> NativeFormViewController {
    let form = NativeFormViewController()
    form.addHeading(title)
    return form
}

#if DEBUG
@MainActor
final class DebugWindowControlsWindowController: ReleasingWindowController {
    static let shared = DebugWindowControlsWindowController()

    override func makeWindow() -> NSWindow {
        let form = nativeDebugForm(
            String(localized: "debug.windows.controls.title", defaultValue: "Debug Window Controls")
        )
        form.addSection(String(localized: "debug.windows.controls.open", defaultValue: "Open"))
        let actions: [(String, () -> Void)] = [
            (String(localized: "debug.menu.browserImportHint", defaultValue: "Browser Import Hint Debug…"), { BrowserImportHintDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.browserProfilePopoverDebug", defaultValue: "Browser Profile Popover Debug…"), { BrowserProfilePopoverDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.aboutTitlebarDebug", defaultValue: "About Titlebar Debug…"), { AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow() }),
            (String(localized: "debug.menu.titlebarLayoutDebug", defaultValue: "Titlebar Layout Debug…"), { TitlebarLayoutDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.sidebar", defaultValue: "Sidebar Debug…"), { SidebarDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.sidebarFooterIconBalance", defaultValue: "Footer Icon Balance Lab…"), { AppDelegate.shared?.debugWindowsCoordinator.showSidebarFooterIconBalanceWindow() }),
            (String(localized: "debug.menu.background", defaultValue: "Background Debug…"), { BackgroundDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.bonsplitTabBarDebug", defaultValue: "Bonsplit Tab Bar Debug…"), { BonsplitTabBarDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.startupAppearanceDebug", defaultValue: "Startup Appearance Debug…"), { StartupAppearanceDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.menuBarExtra", defaultValue: "Menu Bar Extra Debug…"), { MenuBarExtraDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.pdfPreviewChromeDebug", defaultValue: "PDF Preview Chrome Debug…"), { PDFPreviewChromeDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.tabBarBackdropLab", defaultValue: "Tab Bar Backdrop Lab…"), { TabBarBackdropLabWindowController.shared.show() }),
            (String(localized: "debug.menu.splitButtonLayoutDebug", defaultValue: "Split Button Layout Debug…"), { SplitButtonLayoutDebugWindowController.shared.show() }),
            (String(localized: "debug.menu.feedTextEditorDebug", defaultValue: "Feed Text Editor Lab…"), { FeedTextEditorDebugWindowController.shared.show() }),
        ]
        for (title, action) in actions { form.addButton(title, action: action) }
        form.addButton(
            String(localized: "debug.menu.openAllWindows", defaultValue: "Open All Debug Windows")
        ) {
            actions.forEach { $0.1() }
        }

        let defaults = UserDefaults.standard
        form.addSection(String(localized: "debug.windows.controls.workspaceIndicator", defaultValue: "Active Workspace Indicator"))
        let indicator = WorkspaceColorsCatalogSection().indicatorStyle
        form.addPopup(
            String(localized: "debug.common.style", defaultValue: "Style"),
            options: WorkspaceIndicatorStyle.allCases.map { ($0.displayName, $0.rawValue) },
            selectedValue: defaults.string(forKey: indicator.userDefaultsKey) ?? indicator.defaultValue.rawValue
        ) { defaults.set($0, forKey: indicator.userDefaultsKey) }

        form.addSection(String(localized: "debug.windows.controls.devToolsButton", defaultValue: "Browser DevTools Button"))
        form.addPopup(
            String(localized: "debug.common.icon", defaultValue: "Icon"),
            options: BrowserDevToolsIconOption.allCases.map { ($0.title, $0.rawValue) },
            selectedValue: defaults.string(forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)
                ?? BrowserDevToolsButtonDebugSettings.defaultIcon.rawValue
        ) { defaults.set($0, forKey: BrowserDevToolsButtonDebugSettings.iconNameKey) }
        form.addPopup(
            String(localized: "debug.common.color", defaultValue: "Color"),
            options: BrowserDevToolsIconColorOption.allCases.map { ($0.title, $0.rawValue) },
            selectedValue: defaults.string(forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)
                ?? BrowserDevToolsButtonDebugSettings.defaultColor.rawValue
        ) { defaults.set($0, forKey: BrowserDevToolsButtonDebugSettings.iconColorKey) }
        form.addButton(String(localized: "debug.common.copyAllConfig", defaultValue: "Copy All Debug Config")) {
            DebugWindowConfigSnapshot.copyCombinedToPasteboard()
        }
        return makeNativePanel(
            title: String(localized: "debug.windows.controls.title", defaultValue: "Debug Window Controls"),
            identifier: "cmux.debugWindowControls",
            size: NSSize(width: 440, height: 640),
            resizable: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}
#endif

@MainActor
final class BrowserImportHintDebugWindowController: ReleasingWindowController {
    static let shared = BrowserImportHintDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.browserImportHint.title", defaultValue: "Browser Import Hint")
        )
        form.addNote(
            String(localized: "debug.browserImportHint.note", defaultValue: "Preview blank-tab import variants and dismissal state.")
        )
        form.addPopup(
            String(localized: "debug.browserImportHint.variant", defaultValue: "Blank Tab Style"),
            options: BrowserImportHintVariant.allCases.map { (browserImportHintTitle($0), $0.rawValue) },
            selectedValue: BrowserImportHintSettings.variant(
                for: defaults.string(forKey: BrowserImportHintSettings.variantKey)
                    ?? BrowserImportHintSettings.defaultVariant.rawValue
            ).rawValue
        ) { defaults.set($0, forKey: BrowserImportHintSettings.variantKey) }
        form.addCheckbox(
            String(localized: "debug.browserImportHint.showBlankTabs", defaultValue: "Show on blank browser tabs"),
            value: defaults.object(forKey: BrowserImportHintSettings.showOnBlankTabsKey) == nil
                ? BrowserImportHintSettings.defaultShowOnBlankTabs
                : defaults.bool(forKey: BrowserImportHintSettings.showOnBlankTabsKey)
        ) { value in
            defaults.set(value, forKey: BrowserImportHintSettings.showOnBlankTabsKey)
            if value { defaults.set(false, forKey: BrowserImportHintSettings.dismissedKey) }
        }
        form.addCheckbox(
            String(localized: "debug.browserImportHint.dismissed", defaultValue: "Pretend the user dismissed it"),
            value: defaults.object(forKey: BrowserImportHintSettings.dismissedKey) == nil
                ? BrowserImportHintSettings.defaultDismissed
                : defaults.bool(forKey: BrowserImportHintSettings.dismissedKey)
        ) { defaults.set($0, forKey: BrowserImportHintSettings.dismissedKey) }
        form.addButton(String(localized: "debug.browserImportHint.openSettings", defaultValue: "Open Browser Settings")) {
            AppDelegate.presentPreferencesWindow(navigationTarget: .browser)
        }
        form.addButton(String(localized: "debug.browserImportHint.openImport", defaultValue: "Open Import Dialog")) {
            Task { @MainActor in
                await Task.yield()
                BrowserDataImportCoordinator.shared.presentImportDialog()
            }
        }
        form.addButton(String(localized: "debug.browserImportHint.reset", defaultValue: "Reset Hint Debug State")) {
            BrowserImportHintSettings.reset()
        }
        return makeNativePanel(
            title: String(localized: "debug.browserImportHint.windowTitle", defaultValue: "Browser Import Hint Debug"),
            identifier: "cmux.browserImportHintDebug",
            size: NSSize(width: 400, height: 470),
            resizable: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

private func browserImportHintTitle(_ variant: BrowserImportHintVariant) -> String {
    switch variant {
    case .inlineStrip: String(localized: "debug.browserImportHint.inlineStrip", defaultValue: "Inline Strip")
    case .floatingCard: String(localized: "debug.browserImportHint.floatingCard", defaultValue: "Floating Card")
    case .toolbarChip: String(localized: "debug.browserImportHint.toolbarChip", defaultValue: "Toolbar Chip")
    case .settingsOnly: String(localized: "debug.browserImportHint.settingsOnly", defaultValue: "Settings Only")
    }
}

@MainActor
final class BrowserProfilePopoverDebugWindowController: ReleasingWindowController {
    static let shared = BrowserProfilePopoverDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.browserProfilePopover.heading", defaultValue: "Browser Profile Popover")
        )
        form.addNote(
            String(localized: "debug.browserProfilePopover.note", defaultValue: "Tune profile-popover padding live.")
        )
        form.addSlider(
            String(localized: "debug.browserProfilePopover.label.horizontal", defaultValue: "Horizontal"),
            value: BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults),
            range: BrowserProfilePopoverDebugSettings.horizontalPaddingRange,
            format: "%.0f"
        ) { defaults.set(BrowserProfilePopoverDebugSettings.resolvedHorizontalPadding($0), forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey) }
        form.addSlider(
            String(localized: "debug.browserProfilePopover.label.vertical", defaultValue: "Vertical"),
            value: BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults),
            range: BrowserProfilePopoverDebugSettings.verticalPaddingRange,
            format: "%.0f"
        ) { defaults.set(BrowserProfilePopoverDebugSettings.resolvedVerticalPadding($0), forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey) }
        form.addButton(String(localized: "debug.browserProfilePopover.reset", defaultValue: "Reset")) {
            defaults.set(BrowserProfilePopoverDebugSettings.defaultHorizontalPadding, forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
            defaults.set(BrowserProfilePopoverDebugSettings.defaultVerticalPadding, forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)
        }
        return makeNativePanel(
            title: String(localized: "debug.windows.browserProfilePopover.title", defaultValue: "Browser Profile Popover Debug"),
            identifier: "cmux.browserProfilePopoverDebug",
            size: NSSize(width: 380, height: 330),
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

@MainActor
final class AboutWindowController: ReleasingWindowController {
    static let shared = AboutWindowController()

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.about")
        window.contentViewController = NativeAboutViewController()
        window.center()
        AppDelegate.shared?.aboutTitlebarDebugStore.applyCurrentOptions(to: window, for: .about)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        let window = managedWindow()
        AppDelegate.shared?.aboutTitlebarDebugStore.applyCurrentOptions(to: window, for: .about)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class NativeAboutViewController: NSViewController {
    private var targets: [NativeClosureTarget] = []

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: String(localized: "about.appName", defaultValue: "cmux"))
        name.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(name)

        let description = NSTextField(wrappingLabelWithString: String(
            localized: "about.description",
            defaultValue: "A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS."
        ))
        description.alignment = .center
        description.textColor = .secondaryLabelColor
        stack.addArrangedSubview(description)

        let info = Bundle.main.infoDictionary ?? [:]
        addProperty(String(localized: "about.version", defaultValue: "Version"), value: info["CFBundleShortVersionString"] as? String, to: stack)
        addProperty(String(localized: "about.build", defaultValue: "Build"), value: info["CFBundleVersion"] as? String, to: stack)
        let commit = (info["CMUXCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.environment["CMUX_COMMIT"].flatMap { $0.isEmpty ? nil : $0 }
        addProperty(String(localized: "about.commit", defaultValue: "Commit"), value: commit ?? "—", to: stack)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        addButton(String(localized: "about.docs", defaultValue: "Docs"), to: buttons) {
            NSWorkspace.shared.open(URL(string: "https://cmux.com/docs")!)
        }
        addButton(String(localized: "about.github", defaultValue: "GitHub"), to: buttons) {
            NSWorkspace.shared.open(URL(string: "https://github.com/manaflow-ai/cmux")!)
        }
        addButton(String(localized: "about.licenses", defaultValue: "Licenses"), to: buttons) {
            AcknowledgmentsWindowController.shared.show()
        }
        stack.addArrangedSubview(buttons)

        if let copyright = info["NSHumanReadableCopyright"] as? String,
           !copyright.isEmpty {
            let label = NSTextField(wrappingLabelWithString: copyright)
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.isSelectable = true
            stack.addArrangedSubview(label)
        }
        view = background
    }

    private func addProperty(_ label: String, value: String?, to stack: NSStackView) {
        guard let value else { return }
        let key = NSTextField(labelWithString: label)
        key.alignment = .right
        key.translatesAutoresizingMaskIntoConstraints = false
        key.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let content = NSTextField(labelWithString: value)
        content.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        content.textColor = .secondaryLabelColor
        content.isSelectable = true
        let row = NSStackView(views: [key, content])
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)
    }

    private func addButton(_ title: String, to stack: NSStackView, action: @escaping () -> Void) {
        let button = NSButton(title: title, target: nil, action: nil)
        let target = NativeClosureTarget { _ in action() }
        targets.append(target)
        button.target = target
        button.action = #selector(NativeClosureTarget.invoke(_:))
        stack.addArrangedSubview(button)
    }
}

@MainActor
final class AcknowledgmentsWindowController: ReleasingWindowController {
    static let shared = AcknowledgmentsWindowController()

    override func makeWindow() -> NSWindow {
        let textView = NSTextView()
        textView.string = AboutLicenseContent(bundle: .main).load()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        let controller = NSViewController()
        controller.view = scrollView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "about.licenses", defaultValue: "Licenses")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.contentViewController = controller
        window.center()
        return window
    }

    func show() { showManagedWindow(centerWhenHidden: false) }
}

extension Notification.Name {
    static let fileExplorerStyleDidChange = Notification.Name("fileExplorerStyleDidChange")
}

@MainActor
final class FileExplorerStyleDebugWindowController: ReleasingWindowController {
    static let shared = FileExplorerStyleDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.fileExplorerStyle.title", defaultValue: "File Explorer Style")
        )
        let current = FileExplorerStyle(rawValue: defaults.integer(forKey: "fileExplorer.style")) ?? .liquidGlass
        let detail = form.addNote(fileExplorerStyleDescription(current), selectable: true)
        form.addPopup(
            String(localized: "debug.common.style", defaultValue: "Style"),
            options: FileExplorerStyle.allCases.map { ($0.label, String($0.rawValue)) },
            selectedValue: String(current.rawValue)
        ) { value in
            guard let rawValue = Int(value), let style = FileExplorerStyle(rawValue: rawValue) else { return }
            defaults.set(rawValue, forKey: "fileExplorer.style")
            detail.stringValue = fileExplorerStyleDescription(style)
            NotificationCenter.default.post(name: .fileExplorerStyleDidChange, object: nil)
        }
        return makeNativePanel(
            title: String(localized: "debug.fileExplorerStyle.title", defaultValue: "File Explorer Style"),
            identifier: "cmux.fileExplorerStyleDebug",
            size: NSSize(width: 380, height: 280),
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

private func fileExplorerStyleDescription(_ style: FileExplorerStyle) -> String {
    let description: String
    switch style {
    case .liquidGlass: description = String(localized: "debug.fileExplorerStyle.liquidGlass", defaultValue: "Modern macOS, vibrancy, rounded selections")
    case .highDensity: description = String(localized: "debug.fileExplorerStyle.highDensity", defaultValue: "VS Code, compact rows, edge-to-edge")
    case .terminalStealth: description = String(localized: "debug.fileExplorerStyle.terminalStealth", defaultValue: "Monospace, border selection, desaturated")
    case .proStudio: description = String(localized: "debug.fileExplorerStyle.proStudio", defaultValue: "Logic Pro, chunky rows, pill selection")
    case .finder: description = String(localized: "debug.fileExplorerStyle.finder", defaultValue: "Finder sidebar, filled icons, hover tint")
    }
    return "\(description)\nRow \(Int(style.rowHeight)) pt, indent \(Int(style.indentation)) pt, icon \(Int(style.iconSize)) pt"
}

@MainActor
final class SidebarDebugWindowController: ReleasingWindowController {
    static let shared = SidebarDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let tintDefaults = SidebarTintDefaults()
        let form = nativeDebugForm(
            String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        )
        form.addCheckbox(
            String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"),
            value: defaults.bool(forKey: "sidebarMatchTerminalBackground")
        ) { defaults.set($0, forKey: "sidebarMatchTerminalBackground") }
        form.addPopup(
            String(localized: "debug.sidebar.preset", defaultValue: "Preset"),
            options: SidebarPresetOption.allCases.map { ($0.title, $0.rawValue) },
            selectedValue: defaults.string(forKey: "sidebarPreset") ?? SidebarPresetOption.nativeSidebar.rawValue
        ) { value in
            defaults.set(value, forKey: "sidebarPreset")
            guard let preset = SidebarPresetOption(rawValue: value) else { return }
            defaults.set(preset.material.rawValue, forKey: "sidebarMaterial")
            defaults.set(preset.blendMode.rawValue, forKey: "sidebarBlendMode")
            defaults.set(preset.state.rawValue, forKey: "sidebarState")
            defaults.set(preset.tintHex, forKey: "sidebarTintHex")
            defaults.set(preset.tintOpacity, forKey: "sidebarTintOpacity")
            defaults.set(preset.cornerRadius, forKey: "sidebarCornerRadius")
            defaults.set(preset.blurOpacity, forKey: "sidebarBlurOpacity")
        }
        form.addPopup(
            String(localized: "debug.sidebar.material", defaultValue: "Material"),
            options: SidebarMaterialOption.allCases.map { ($0.title, $0.rawValue) },
            selectedValue: defaults.string(forKey: "sidebarMaterial") ?? SidebarMaterialOption.sidebar.rawValue
        ) { defaults.set($0, forKey: "sidebarMaterial") }
        form.addPopup(
            String(localized: "debug.sidebar.blending", defaultValue: "Blending"),
            options: SidebarBlendModeOption.allCases.map { ($0.title, $0.rawValue) },
            selectedValue: defaults.string(forKey: "sidebarBlendMode") ?? SidebarBlendModeOption.withinWindow.rawValue
        ) { defaults.set($0, forKey: "sidebarBlendMode") }
        form.addPopup(
            String(localized: "debug.sidebar.state", defaultValue: "State"),
            options: SidebarStateOption.allCases.map { ($0.title, $0.rawValue) },
            selectedValue: defaults.string(forKey: "sidebarState") ?? SidebarStateOption.followWindow.rawValue
        ) { defaults.set($0, forKey: "sidebarState") }
        form.addSlider(
            String(localized: "debug.sidebar.blurStrength", defaultValue: "Blur Strength"),
            value: defaults.object(forKey: "sidebarBlurOpacity") as? Double ?? 1,
            range: 0...1,
            format: "%.2f"
        ) { defaults.set($0, forKey: "sidebarBlurOpacity") }
        form.addSlider(
            String(localized: "debug.sidebar.tintOpacity", defaultValue: "Tint Opacity"),
            value: defaults.object(forKey: "sidebarTintOpacity") as? Double ?? tintDefaults.opacity,
            range: 0...0.7,
            format: "%.2f"
        ) { defaults.set($0, forKey: "sidebarTintOpacity") }
        form.addColorWell(
            String(localized: "debug.sidebar.tintColor", defaultValue: "Tint Color"),
            color: NSColor(hex: defaults.string(forKey: "sidebarTintHex") ?? tintDefaults.hex) ?? .black
        ) { defaults.set($0.hexString(), forKey: "sidebarTintHex") }
        form.addSlider(
            String(localized: "debug.sidebar.cornerRadius", defaultValue: "Corner Radius"),
            value: defaults.object(forKey: "sidebarCornerRadius") as? Double ?? 0,
            range: 0...20,
            format: "%.0f"
        ) { defaults.set($0, forKey: "sidebarCornerRadius") }
        let sidebarCatalog = SidebarCatalogSection()
        form.addCheckbox(
            String(localized: "debug.sidebar.verticalBranches", defaultValue: "Render branch list vertically"),
            value: defaults.object(forKey: sidebarCatalog.branchVerticalLayout.userDefaultsKey) == nil
                ? sidebarCatalog.branchVerticalLayout.defaultValue
                : defaults.bool(forKey: sidebarCatalog.branchVerticalLayout.userDefaultsKey)
        ) { defaults.set($0, forKey: sidebarCatalog.branchVerticalLayout.userDefaultsKey) }
        form.addButton(String(localized: "debug.common.copyConfig", defaultValue: "Copy Config")) {
            DebugWindowConfigSnapshot.copyCombinedToPasteboard(defaults: defaults)
        }
        return makeNativePanel(
            title: String(localized: "debug.sidebar.windowTitle", defaultValue: "Sidebar Debug"),
            identifier: "cmux.sidebarDebug",
            size: NSSize(width: 430, height: 620),
            resizable: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

#if DEBUG
private enum NativeSidebarFooterOpticalBalanceSettings {
    static let blurRadiusKey = "debug.sidebarFooterIconBalance.blurRadius"
    static let showsCellGuidesKey = "debug.sidebarFooterIconBalance.showsCellGuides"
}

@MainActor
final class SidebarFooterIconBalanceDebugWindowController: ReleasingWindowController {
    private weak var decorator: (any WindowDecorating)?

    init(decorator: (any WindowDecorating)?) {
        self.decorator = decorator
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.sidebarFooterIconBalance.title", defaultValue: "Footer Icon Balance Lab")
        )
        let preview = NativeSidebarFooterPreviewView()
        form.addCustomView(preview)
        form.addPopup(
            String(localized: "debug.sidebarFooterIconBalance.profileIcon", defaultValue: "Profile Icon"),
            options: SidebarFooterProfileIconDebugChoice.allCases.map { ($0.rawValue, $0.rawValue) },
            selectedValue: defaults.string(forKey: SidebarFooterProfileIconDebugSettings.iconKey)
                ?? SidebarFooterProfileIconDebugSettings.defaultIcon.rawValue
        ) { defaults.set($0, forKey: SidebarFooterProfileIconDebugSettings.iconKey); preview.refresh() }
        form.addSlider(
            String(localized: "debug.sidebarFooterIconBalance.profileSize", defaultValue: "Profile Size"),
            value: defaults.object(forKey: SidebarFooterProfileIconDebugSettings.sizeKey) as? Double
                ?? SidebarFooterProfileIconDebugSettings.defaultSize,
            range: 10...20
        ) { defaults.set($0, forKey: SidebarFooterProfileIconDebugSettings.sizeKey); preview.refresh() }
        form.addPopup(
            String(localized: "debug.sidebarFooterIconBalance.helpIcon", defaultValue: "Help Icon"),
            options: SidebarFooterHelpIconDebugChoice.allCases.map { ($0.rawValue, $0.rawValue) },
            selectedValue: defaults.string(forKey: SidebarFooterHelpIconDebugSettings.iconKey)
                ?? SidebarFooterHelpIconDebugSettings.defaultIcon.rawValue
        ) { defaults.set($0, forKey: SidebarFooterHelpIconDebugSettings.iconKey); preview.refresh() }
        form.addPopup(
            String(localized: "debug.sidebarFooterIconBalance.helpWeight", defaultValue: "Help Weight"),
            options: SidebarFooterHelpIconDebugWeight.allCases.map { ($0.displayName, $0.rawValue) },
            selectedValue: defaults.string(forKey: SidebarFooterHelpIconDebugSettings.weightKey)
                ?? SidebarFooterHelpIconDebugSettings.defaultWeight.rawValue
        ) { defaults.set($0, forKey: SidebarFooterHelpIconDebugSettings.weightKey); preview.refresh() }
        form.addSlider(
            String(localized: "debug.sidebarFooterIconBalance.helpSize", defaultValue: "Help Size"),
            value: defaults.object(forKey: SidebarFooterHelpIconDebugSettings.sizeKey) as? Double
                ?? SidebarFooterHelpIconDebugSettings.defaultSize,
            range: 10...20
        ) { defaults.set($0, forKey: SidebarFooterHelpIconDebugSettings.sizeKey); preview.refresh() }
        form.addSlider(
            String(localized: "debug.sidebarFooterIconBalance.mobileSize", defaultValue: "Mobile Size"),
            value: defaults.object(forKey: SidebarFooterMobileIconDebugSettings.sizeKey) as? Double
                ?? SidebarFooterMobileIconDebugSettings.defaultSize,
            range: 8...20
        ) { defaults.set($0, forKey: SidebarFooterMobileIconDebugSettings.sizeKey); preview.refresh() }
        form.addSlider(
            String(localized: "debug.sidebarFooterIconBalance.hoverOpacity", defaultValue: "Hover Opacity"),
            value: defaults.object(forKey: SidebarFooterIconButtonDebugSettings.hoverOpacityKey) as? Double
                ?? SidebarFooterIconButtonDebugSettings.defaultHoverOpacity,
            range: 0...0.3,
            format: "%.2f"
        ) { defaults.set($0, forKey: SidebarFooterIconButtonDebugSettings.hoverOpacityKey); preview.refresh() }
        form.addCheckbox(
            String(localized: "debug.sidebarFooterIconBalance.cellGuides", defaultValue: "Show Cell Guides"),
            value: defaults.object(forKey: NativeSidebarFooterOpticalBalanceSettings.showsCellGuidesKey) == nil
                ? true
                : defaults.bool(forKey: NativeSidebarFooterOpticalBalanceSettings.showsCellGuidesKey)
        ) { defaults.set($0, forKey: NativeSidebarFooterOpticalBalanceSettings.showsCellGuidesKey); preview.refresh() }
        let panel = makeNativePanel(
            title: String(localized: "debug.sidebarFooterIconBalance.title", defaultValue: "Footer Icon Balance Lab"),
            identifier: "cmux.sidebarFooterIconBalanceDebug",
            size: NSSize(width: 720, height: 620),
            resizable: true,
            contentViewController: form
        )
        decorator?.applyWindowDecorations(to: panel)
        return panel
    }

    func show() { showManagedWindow(activateApplication: true) }
}

@MainActor
private final class NativeSidebarFooterPreviewView: NSView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 90).isActive = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let defaults = UserDefaults.standard
        let profileName = defaults.string(forKey: SidebarFooterProfileIconDebugSettings.iconKey)
            ?? SidebarFooterProfileIconDebugSettings.defaultIcon.rawValue
        let helpName = defaults.string(forKey: SidebarFooterHelpIconDebugSettings.iconKey)
            ?? SidebarFooterHelpIconDebugSettings.defaultIcon.rawValue
        let items = [
            (profileName, defaults.object(forKey: SidebarFooterProfileIconDebugSettings.sizeKey) as? Double ?? SidebarFooterProfileIconDebugSettings.defaultSize),
            ("iphone", defaults.object(forKey: SidebarFooterMobileIconDebugSettings.sizeKey) as? Double ?? SidebarFooterMobileIconDebugSettings.defaultSize),
            (helpName, defaults.object(forKey: SidebarFooterHelpIconDebugSettings.sizeKey) as? Double ?? SidebarFooterHelpIconDebugSettings.defaultSize),
        ]
        for (name, size) in items {
            let imageView = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: name) ?? NSImage())
            imageView.contentTintColor = .secondaryLabelColor
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            stack.addArrangedSubview(imageView)
        }
    }
}
#endif

@MainActor
final class MenuBarExtraDebugWindowController: ReleasingWindowController {
    static let shared = MenuBarExtraDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.menuBarExtra.title", defaultValue: "Menu Bar Extra Icon")
        )
        let refresh = { AppDelegate.shared?.refreshMenuBarExtraForDebug() }
        form.addCheckbox(
            String(localized: "debug.menuBarExtra.overrideCount", defaultValue: "Override unread count"),
            value: defaults.bool(forKey: MenuBarIconDebugSettings.previewEnabledKey)
        ) { defaults.set($0, forKey: MenuBarIconDebugSettings.previewEnabledKey); refresh() }
        form.addSlider(
            String(localized: "debug.menuBarExtra.unreadCount", defaultValue: "Unread Count"),
            value: Double(defaults.integer(forKey: MenuBarIconDebugSettings.previewCountKey)),
            range: 0...99,
            format: "%.0f"
        ) { defaults.set(Int($0.rounded()), forKey: MenuBarIconDebugSettings.previewCountKey); refresh() }
        let sliders: [(String, String, Double, ClosedRange<Double>)] = [
            (String(localized: "debug.menuBarExtra.badgeX", defaultValue: "Badge X"), MenuBarIconDebugSettings.badgeRectXKey, Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.x), 0...20),
            (String(localized: "debug.menuBarExtra.badgeY", defaultValue: "Badge Y"), MenuBarIconDebugSettings.badgeRectYKey, Double(MenuBarIconDebugSettings.defaultBadgeRect.origin.y), 0...20),
            (String(localized: "debug.menuBarExtra.badgeWidth", defaultValue: "Badge Width"), MenuBarIconDebugSettings.badgeRectWidthKey, Double(MenuBarIconDebugSettings.defaultBadgeRect.width), 4...14),
            (String(localized: "debug.menuBarExtra.badgeHeight", defaultValue: "Badge Height"), MenuBarIconDebugSettings.badgeRectHeightKey, Double(MenuBarIconDebugSettings.defaultBadgeRect.height), 4...14),
            (String(localized: "debug.menuBarExtra.singleSize", defaultValue: "1-digit Size"), MenuBarIconDebugSettings.singleDigitFontSizeKey, Double(MenuBarIconDebugSettings.defaultSingleDigitFontSize), 6...14),
            (String(localized: "debug.menuBarExtra.multiSize", defaultValue: "2-digit Size"), MenuBarIconDebugSettings.multiDigitFontSizeKey, Double(MenuBarIconDebugSettings.defaultMultiDigitFontSize), 6...14),
            (String(localized: "debug.menuBarExtra.singleX", defaultValue: "1-digit X"), MenuBarIconDebugSettings.singleDigitXAdjustKey, Double(MenuBarIconDebugSettings.defaultSingleDigitXAdjust), -4...4),
            (String(localized: "debug.menuBarExtra.multiX", defaultValue: "2-digit X"), MenuBarIconDebugSettings.multiDigitXAdjustKey, Double(MenuBarIconDebugSettings.defaultMultiDigitXAdjust), -4...4),
            (String(localized: "debug.menuBarExtra.singleY", defaultValue: "1-digit Y"), MenuBarIconDebugSettings.singleDigitYOffsetKey, Double(MenuBarIconDebugSettings.defaultSingleDigitYOffset), -3...4),
            (String(localized: "debug.menuBarExtra.multiY", defaultValue: "2-digit Y"), MenuBarIconDebugSettings.multiDigitYOffsetKey, Double(MenuBarIconDebugSettings.defaultMultiDigitYOffset), -3...4),
        ]
        for (title, key, fallback, range) in sliders {
            form.addSlider(title, value: defaults.object(forKey: key) as? Double ?? fallback, range: range, format: "%.2f") {
                defaults.set($0, forKey: key)
                refresh()
            }
        }
        form.addButton(String(localized: "debug.common.copyConfig", defaultValue: "Copy Config")) {
            copyToPasteboard(MenuBarIconDebugSettings.copyPayload(defaults: defaults))
        }
        return makeNativePanel(
            title: String(localized: "debug.menuBarExtra.windowTitle", defaultValue: "Menu Bar Extra Debug"),
            identifier: "cmux.menubarDebug",
            size: NSSize(width: 450, height: 620),
            resizable: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

#if DEBUG
@MainActor
final class SplitButtonLayoutDebugWindowController: ReleasingWindowController {
    static let shared = SplitButtonLayoutDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.splitButtonLayout.title", defaultValue: "Button Backdrop Color")
        )
        let preview = NSStackView(views: [
            NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil),
            NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil),
        ])
        preview.orientation = .horizontal
        preview.spacing = 0
        form.addCustomView(preview)
        form.addPopup(
            String(localized: "debug.splitButtonLayout.controlsStyle", defaultValue: "Controls Style"),
            options: TitlebarControlsStyle.allCases.map { ($0.menuTitle, String($0.rawValue)) },
            selectedValue: String(TitlebarControlsStyle.stored(in: defaults).rawValue)
        ) { value in
            if let rawValue = Int(value) { defaults.set(rawValue, forKey: TitlebarControlsStyle.storageKey) }
        }
        form.addCheckbox(
            String(localized: "debug.splitButtonLayout.alwaysHover", defaultValue: "Always Show Hover State"),
            value: defaults.bool(forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.alwaysHoverKey)
        ) { defaults.set($0, forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.alwaysHoverKey) }
        form.addPopup(
            String(localized: "debug.splitButtonLayout.hoverSegment", defaultValue: "Forced Hover Segment"),
            options: TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment.allCases.map { ($0.rawValue, $0.rawValue) },
            selectedValue: defaults.string(forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.forcedHoverSegmentKey)
                ?? TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultForcedHoverSegment.rawValue
        ) { defaults.set($0, forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.forcedHoverSegmentKey) }
        let sliderDefinitions: [(String, String, Double, ClosedRange<Double>)] = [
            (String(localized: "debug.splitButtonLayout.width.plusOffset", defaultValue: "Plus Width Offset"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusWidthOffsetKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPlusWidthOffset, -12...24),
            (String(localized: "debug.splitButtonLayout.width.caretOffset", defaultValue: "Caret Width Offset"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretWidthOffsetKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultCaretWidthOffset, -10...24),
            (String(localized: "debug.splitButtonLayout.plusTop", defaultValue: "Plus Top"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingTopKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
            (String(localized: "debug.splitButtonLayout.plusLeading", defaultValue: "Plus Leading"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingLeadingKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
            (String(localized: "debug.splitButtonLayout.plusBottom", defaultValue: "Plus Bottom"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingBottomKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
            (String(localized: "debug.splitButtonLayout.plusTrailing", defaultValue: "Plus Trailing"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusPaddingTrailingKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPlusPaddingTrailing, -8...8),
            (String(localized: "debug.splitButtonLayout.caretTop", defaultValue: "Caret Top"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingTopKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
            (String(localized: "debug.splitButtonLayout.caretLeading", defaultValue: "Caret Leading"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingLeadingKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
            (String(localized: "debug.splitButtonLayout.caretBottom", defaultValue: "Caret Bottom"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingBottomKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
            (String(localized: "debug.splitButtonLayout.caretTrailing", defaultValue: "Caret Trailing"), TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretPaddingTrailingKey, TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPadding, -8...8),
        ]
        for (title, key, fallback, range) in sliderDefinitions {
            form.addSlider(title, value: defaults.object(forKey: key) as? Double ?? fallback, range: range) {
                defaults.set($0, forKey: key)
            }
        }
        form.addPopup(
            String(localized: "debug.splitButtonLayout.backdropOptions", defaultValue: "Backdrop"),
            options: (0...7).map { (String($0), String($0)) },
            selectedValue: String(defaults.integer(forKey: "debugFadeColorStyle"))
        ) { if let value = Int($0) { defaults.set(value, forKey: "debugFadeColorStyle") } }
        return makeNativePanel(
            title: String(localized: "debug.splitButtonLayout.windowTitle", defaultValue: "Split Button Layout"),
            identifier: "cmux.splitButtonLayoutDebug",
            size: NSSize(width: 470, height: 680),
            resizable: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}
#endif

@MainActor
final class TabBarBackdropLabWindowController: ReleasingWindowController {
    static let shared = TabBarBackdropLabWindowController()

    override func makeWindow() -> NSWindow {
        let form = nativeDebugForm(
            String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab")
        )
        form.addNote(
            String(localized: "debug.tabBarBackdropLab.subtitle", defaultValue: "Native AppKit samples for tab-bar backdrop coverage and fade softness.")
        )
        let preview = NativeTabBarBackdropPreviewView()
        form.addCustomView(preview)
        form.addSlider(
            String(localized: "debug.tabBarBackdropLab.opacity", defaultValue: "Surface Opacity"),
            value: preview.opacity,
            range: 0.2...1,
            format: "%.2f"
        ) { preview.opacity = $0; preview.needsDisplay = true }
        form.addSlider(
            String(localized: "debug.tabBarBackdropLab.candidateSoftness", defaultValue: "Candidate Softness"),
            value: preview.softness,
            range: 0...1,
            format: "%.2f"
        ) { preview.softness = $0; preview.needsDisplay = true }
        return makeNativePanel(
            title: String(localized: "debug.tabBarBackdropLab.title", defaultValue: "Tab Bar Backdrop Lab"),
            identifier: "cmux.tabBarBackdropLab",
            size: NSSize(width: 820, height: 520),
            resizable: true,
            fullSizeContent: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow(orderFrontRegardless: true) }
}

@MainActor
private final class NativeTabBarBackdropPreviewView: NSView {
    var opacity = 0.72
    var softness = Double(Workspace.bonsplitSplitButtonBackdropSoftness)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 280).isActive = true
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let base = GhosttyApp.shared.defaultBackgroundColor.withAlphaComponent(opacity)
        base.setFill()
        NSBezierPath(rect: bounds).fill()
        let tabBar = NSRect(x: 18, y: bounds.maxY - 64, width: bounds.width - 36, height: 42)
        NSColor.windowBackgroundColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: tabBar, xRadius: 8, yRadius: 8).fill()

        let tabWidth: CGFloat = 130
        for index in 0..<5 {
            let tab = NSRect(x: tabBar.minX + 8 + CGFloat(index) * (tabWidth + 4), y: tabBar.minY + 6, width: tabWidth, height: 30)
            (index == 0 ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.controlColor.withAlphaComponent(0.3)).setFill()
            NSBezierPath(roundedRect: tab, xRadius: 6, yRadius: 6).fill()
        }

        let fadeWidth = max(30, CGFloat(softness) * 220)
        let fadeRect = NSRect(x: tabBar.maxX - fadeWidth, y: tabBar.minY, width: fadeWidth, height: tabBar.height)
        let gradient = NSGradient(
            starting: NSColor.windowBackgroundColor.withAlphaComponent(0),
            ending: NSColor.windowBackgroundColor.withAlphaComponent(opacity)
        )
        gradient?.draw(in: fadeRect, angle: 0)
        let buttonRect = NSRect(x: tabBar.maxX - 78, y: tabBar.minY + 6, width: 64, height: 30)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor
final class BackgroundDebugWindowController: ReleasingWindowController {
    static let shared = BackgroundDebugWindowController()

    override func makeWindow() -> NSWindow {
        let defaults = UserDefaults.standard
        let form = nativeDebugForm(
            String(localized: "debug.background.title", defaultValue: "Window Background Glass")
        )
        form.addCheckbox(
            String(localized: "debug.background.enabled", defaultValue: "Enable Glass Effect"),
            value: defaults.bool(forKey: "bgGlassEnabled")
        ) { defaults.set($0, forKey: "bgGlassEnabled") }
        form.addPopup(
            String(localized: "debug.background.material", defaultValue: "Material"),
            options: [
                (String(localized: "debug.background.hud", defaultValue: "HUD Window"), "hudWindow"),
                (String(localized: "debug.background.underWindow", defaultValue: "Under Window"), "underWindowBackground"),
                (String(localized: "debug.background.sidebar", defaultValue: "Sidebar"), "sidebar"),
                (String(localized: "debug.background.menu", defaultValue: "Menu"), "menu"),
                (String(localized: "debug.background.popover", defaultValue: "Popover"), "popover"),
            ],
            selectedValue: defaults.string(forKey: "bgGlassMaterial") ?? "hudWindow"
        ) { defaults.set($0, forKey: "bgGlassMaterial") }
        let updateTint = {
            guard let window = NSApp.windows.first(where: {
                guard let id = $0.identifier?.rawValue else { return false }
                return id == "cmux.main" || id.hasPrefix("cmux.main.")
            }) else { return }
            let color = NSColor(hex: defaults.string(forKey: "bgGlassTintHex") ?? "#000000") ?? .black
            let opacity = defaults.object(forKey: "bgGlassTintOpacity") as? Double ?? 0.03
            AppWindowChromeComposition().backdropController.updateGlassTint(
                to: window,
                color: color.withAlphaComponent(opacity)
            )
        }
        form.addColorWell(
            String(localized: "debug.background.tintColor", defaultValue: "Tint Color"),
            color: NSColor(hex: defaults.string(forKey: "bgGlassTintHex") ?? "#000000") ?? .black
        ) { defaults.set($0.hexString(), forKey: "bgGlassTintHex"); updateTint() }
        form.addSlider(
            String(localized: "debug.background.tintOpacity", defaultValue: "Tint Opacity"),
            value: defaults.object(forKey: "bgGlassTintOpacity") as? Double ?? 0.03,
            range: 0...0.8,
            format: "%.2f"
        ) { defaults.set($0, forKey: "bgGlassTintOpacity"); updateTint() }
        form.addButton(String(localized: "debug.common.copyConfig", defaultValue: "Copy Config")) {
            copyToPasteboard("""
            bgGlassEnabled=\(defaults.bool(forKey: "bgGlassEnabled"))
            bgGlassMaterial=\(defaults.string(forKey: "bgGlassMaterial") ?? "hudWindow")
            bgGlassTintHex=\(defaults.string(forKey: "bgGlassTintHex") ?? "#000000")
            bgGlassTintOpacity=\(String(format: "%.2f", defaults.object(forKey: "bgGlassTintOpacity") as? Double ?? 0.03))
            """)
        }
        return makeNativePanel(
            title: String(localized: "debug.background.windowTitle", defaultValue: "Background Debug"),
            identifier: "cmux.backgroundDebug",
            size: NSSize(width: 400, height: 390),
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

private enum StartupAppearancePreviewMode: String, CaseIterable {
    case stored
    case light
    case dark

    var displayName: String {
        switch self {
        case .stored: String(localized: "debug.startupAppearance.mode.stored", defaultValue: "Stored App Setting")
        case .light: String(localized: "debug.startupAppearance.mode.light", defaultValue: "Force Light")
        case .dark: String(localized: "debug.startupAppearance.mode.dark", defaultValue: "Force Dark")
        }
    }
}

@MainActor
final class StartupAppearanceDebugWindowController: ReleasingWindowController {
    static let shared = StartupAppearanceDebugWindowController()

    override func makeWindow() -> NSWindow {
        let form = nativeDebugForm(
            String(localized: "debug.startupAppearance.window.title", defaultValue: "Startup Appearance Debug")
        )
        var profile = GhosttyStartupAppearancePreviewState.profile
        var appearance = StartupAppearancePreviewMode.stored
        let configLabel = form.addNote(
            profile.previewConfigContents()
                ?? String(localized: "debug.startupAppearance.realConfigFallback", defaultValue: "Loads real user config files."),
            selectable: true
        )
        form.addPopup(
            String(localized: "debug.startupAppearance.startupConfig.label", defaultValue: "Startup Config"),
            options: GhosttyStartupAppearancePreviewProfile.allCases.map { ($0.displayName, $0.rawValue) },
            selectedValue: profile.rawValue
        ) { value in
            guard let selected = GhosttyStartupAppearancePreviewProfile(rawValue: value) else { return }
            profile = selected
            configLabel.stringValue = selected.previewConfigContents()
                ?? String(localized: "debug.startupAppearance.realConfigFallback", defaultValue: "Loads real user config files.")
        }
        form.addPopup(
            String(localized: "debug.startupAppearance.appearance.label", defaultValue: "Appearance"),
            options: StartupAppearancePreviewMode.allCases.map { ($0.displayName, $0.rawValue) },
            selectedValue: appearance.rawValue
        ) { appearance = StartupAppearancePreviewMode(rawValue: $0) ?? .stored }
        form.addButton(
            String(localized: "debug.startupAppearance.applyPreview.button", defaultValue: "Apply Preview")
        ) {
            applyStartupAppearance(appearance)
            GhosttyStartupAppearancePreviewState.profile = profile
            GhosttyConfig.invalidateLoadCache()
            AppDelegate.shared?.reloadConfiguration(
                source: "debug.startupAppearancePreview",
                reloadSettingsFromFile: false
            )
        }
        form.addButton(
            String(localized: "debug.startupAppearance.restoreRealStartup.button", defaultValue: "Restore Real Startup")
        ) {
            profile = .realUserConfig
            appearance = .stored
            applyStartupAppearance(.stored)
            GhosttyStartupAppearancePreviewState.profile = .realUserConfig
            GhosttyConfig.invalidateLoadCache()
            AppDelegate.shared?.reloadConfiguration(
                source: "debug.startupAppearanceRestore",
                reloadSettingsFromFile: false
            )
        }
        form.addButton(
            String(localized: "debug.startupAppearance.copySelectedConfig.button", defaultValue: "Copy Selected Config")
        ) {
            guard let value = profile.previewConfigContents() else { return }
            copyToPasteboard(value)
        }
        return makeNativePanel(
            title: String(localized: "debug.startupAppearance.window.title", defaultValue: "Startup Appearance Debug"),
            identifier: "cmux.startupAppearanceDebug",
            size: NSSize(width: 500, height: 500),
            resizable: true,
            contentViewController: form
        )
    }

    func show() { showManagedWindow() }
}

@MainActor
private func applyStartupAppearance(_ mode: StartupAppearancePreviewMode) {
    switch mode {
    case .stored:
        switch AppearanceSettings.resolvedMode() {
        case .system, .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    case .light:
        NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}
