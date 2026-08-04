import AppKit
import CmuxSettings

enum TitlebarNewWorkspaceCloudSplitButtonMetrics {
    static func primaryWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(config.iconSize + 4, config.buttonSize - 3)
    }

    static func dropdownWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(14, floor(config.buttonSize * 0.70))
    }

    static func dropdownIconSize(config: TitlebarControlsStyleConfig) -> CGFloat {
        max(6, config.iconSize - 6)
    }

    static func totalWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        primaryWidth(config: config) + dropdownWidth(config: config)
    }
}

#if DEBUG
enum TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment: String, CaseIterable, Identifiable {
    case newTab
    case cloudMenu
    case both

    var id: String { rawValue }

    static func stored(rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .newTab
    }

    fileprivate func includes(_ segment: TitlebarNewWorkspaceCloudSplitButtonSegment) -> Bool {
        switch (self, segment) {
        case (.newTab, .newTab), (.cloudMenu, .cloudMenu), (.both, _):
            true
        default:
            false
        }
    }
}

enum TitlebarNewWorkspaceCloudSplitButtonDebugSettings {
    static let alwaysHoverKey = "debugTitlebarSplitButtonAlwaysHover"
    static let forcedHoverSegmentKey = "debugTitlebarSplitButtonForcedHoverSegment"
    static let plusWidthOffsetKey = "debugTitlebarSplitButtonPlusWidthOffset"
    static let caretWidthOffsetKey = "debugTitlebarSplitButtonCaretWidthOffset"
    static let plusPaddingTopKey = "debugTitlebarSplitButtonPlusPaddingTop"
    static let plusPaddingLeadingKey = "debugTitlebarSplitButtonPlusPaddingLeading"
    static let plusPaddingBottomKey = "debugTitlebarSplitButtonPlusPaddingBottom"
    static let plusPaddingTrailingKey = "debugTitlebarSplitButtonPlusPaddingTrailing"
    static let caretPaddingTopKey = "debugTitlebarSplitButtonCaretPaddingTop"
    static let caretPaddingLeadingKey = "debugTitlebarSplitButtonCaretPaddingLeading"
    static let caretPaddingBottomKey = "debugTitlebarSplitButtonCaretPaddingBottom"
    static let caretPaddingTrailingKey = "debugTitlebarSplitButtonCaretPaddingTrailing"

    static let defaultAlwaysHover = false
    static let defaultForcedHoverSegment = TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment.newTab
    static let defaultPlusWidthOffset = -12.0
    static let defaultCaretWidthOffset = -10.0
    static let defaultPadding = 0.0
    static let defaultPlusPaddingTrailing = -0.7
}
#endif

@MainActor
final class TitlebarNativeButton: NSButton {
    var config = TitlebarControlsStyle.classic.config {
        didSet { refreshSymbolAndAppearance() }
    }
    var onRightMouseDown: ((NSView, NSEvent) -> Void)?
    var groupIsHovering = false {
        didSet { refreshAppearance() }
    }
    var forceActiveHover = false {
        didSet { refreshAppearance() }
    }
    var onHoverChanged: ((Bool) -> Void)?

    private let symbolName: String
    private let symbolWeight: NSFont.Weight
    private let symbolSize: (TitlebarControlsStyleConfig) -> CGFloat
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false
    private var isPressed = false

    init(
        symbolName: String,
        symbolWeight: NSFont.Weight = .regular,
        symbolSize: @escaping (TitlebarControlsStyleConfig) -> CGFloat = { $0.iconSize }
    ) {
        self.symbolName = symbolName
        self.symbolWeight = symbolWeight
        self.symbolSize = symbolSize
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        refusesFirstResponder = true
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.masksToBounds = true
        refreshSymbolAndAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var isEnabled: Bool {
        didSet { refreshAppearance() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        trackingAreaReference = next
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onHoverChanged?(true)
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        onHoverChanged?(false)
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        refreshAppearance()
        super.mouseDown(with: event)
        isPressed = false
        refreshAppearance()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightMouseDown {
            onRightMouseDown(self, event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    func refreshSymbolAndAppearance() {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: symbolSize(config),
            weight: symbolWeight
        )
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel())?
            .withSymbolConfiguration(configuration)
        refreshAppearance()
    }

    func refreshAppearance() {
        let activeHover = forceActiveHover || isPointerInside
        let visibleHover = activeHover || groupIsHovering
        let foregroundOpacity = titlebarControlForegroundOpacity(
            isHovering: visibleHover,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
        contentTintColor = titlebarControlForegroundNSColor(opacity: foregroundOpacity)

        let baseBackground = titlebarControlBackgroundOpacity(
            config: config,
            isHovering: activeHover,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
        let activeBackground = titlebarControlActiveHoverBackgroundOpacity(
            isHovering: activeHover,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
        let passiveBackground = titlebarControlPassiveHoverBackgroundOpacity(
            isHovering: groupIsHovering && !activeHover,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
        let backgroundOpacity = max(baseBackground, activeBackground, passiveBackground)
        if backgroundOpacity > 0 {
            layer?.backgroundColor = titlebarControlForegroundNSColor(opacity: backgroundOpacity).cgColor
        } else if config.buttonBackground {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        let borderOpacity = titlebarControlBorderOpacity(
            config: config,
            isHovering: visibleHover,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
        layer?.cornerRadius = config.buttonCornerRadius
        layer?.borderWidth = borderOpacity > 0 ? 0.5 : 0
        layer?.borderColor = titlebarControlForegroundNSColor(opacity: borderOpacity).cgColor
    }
}

private enum TitlebarNewWorkspaceCloudSplitButtonSegment: Equatable {
    case newTab
    case cloudMenu
}

@MainActor
final class TitlebarNewWorkspaceCloudSplitButton: NSView {
    var config: TitlebarControlsStyleConfig {
        didSet { refreshConfiguration() }
    }
    var foregroundColor: NSColor {
        didSet { refreshConfiguration() }
    }
    var onNewTab: () -> Void

    private let newTabButton = TitlebarNativeButton(symbolName: "plus", symbolWeight: .medium)
    private let cloudMenuButton = TitlebarNativeButton(
        symbolName: "chevron.down",
        symbolWeight: .bold,
        symbolSize: TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownIconSize(config:)
    )
    private var hoveredSegment: TitlebarNewWorkspaceCloudSplitButtonSegment?

    init(
        config: TitlebarControlsStyleConfig,
        foregroundColor: NSColor = titlebarControlForegroundNSColor(opacity: 1),
        onNewTab: @escaping () -> Void
    ) {
        self.config = config
        self.foregroundColor = foregroundColor
        self.onNewTab = onNewTab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(newTabButton)
        addSubview(cloudMenuButton)

        newTabButton.target = self
        newTabButton.action = #selector(createWorkspace(_:))
        newTabButton.identifier = NSUserInterfaceItemIdentifier("titlebarControl.newTab")
        newTabButton.setAccessibilityIdentifier("titlebarControl.newTab")
        newTabButton.setAccessibilityLabel(
            String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace")
        )
        newTabButton.toolTip = KeyboardShortcutSettings.Action.newTab.tooltip(
            String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")
        )
        newTabButton.onRightMouseDown = { anchorView, event in
            _ = AppDelegate.shared?.showNewWorkspaceContextMenu(anchorView: anchorView, event: event)
        }
        newTabButton.onHoverChanged = { [weak self] hovering in
            self?.setHovered(.newTab, hovering: hovering)
        }

        cloudMenuButton.target = self
        cloudMenuButton.action = #selector(showWorkspaceMenu(_:))
        cloudMenuButton.identifier = NSUserInterfaceItemIdentifier("titlebarControl.cloudVM")
        cloudMenuButton.setAccessibilityIdentifier("titlebarControl.cloudVM")
        cloudMenuButton.setAccessibilityLabel(
            String(localized: "titlebar.cloudVM.menu.accessibilityLabel", defaultValue: "Cloud VM Menu")
        )
        cloudMenuButton.toolTip = String(
            localized: "titlebar.cloudVM.menu.tooltip",
            defaultValue: "Cloud VM actions"
        )
        cloudMenuButton.onRightMouseDown = { anchorView, event in
            _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                anchorView: anchorView,
                event: event,
                debugSource: "titlebar.newWorkspace.cloudMenu.rightClick"
            )
        }
        cloudMenuButton.onHoverChanged = { [weak self] hovering in
            self?.setHovered(.cloudMenu, hovering: hovering)
        }

        refreshConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: primaryWidth + dropdownWidth, height: config.buttonSize)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        let height = min(bounds.height, config.buttonSize)
        let y = max(0, (bounds.height - height) / 2)
        newTabButton.frame = NSRect(x: 0, y: y, width: primaryWidth, height: height)
        cloudMenuButton.frame = NSRect(x: primaryWidth, y: y, width: dropdownWidth, height: height)
        layer?.cornerRadius = config.buttonCornerRadius
    }

    func update(
        config: TitlebarControlsStyleConfig,
        foregroundColor: NSColor,
        onNewTab: @escaping () -> Void
    ) {
        self.config = config
        self.foregroundColor = foregroundColor
        self.onNewTab = onNewTab
        refreshConfiguration()
    }

    var cloudMenuAnchorView: NSView { cloudMenuButton }

    private var primaryWidth: CGFloat {
        let base = TitlebarNewWorkspaceCloudSplitButtonMetrics.primaryWidth(config: config)
        #if DEBUG
        let offset = UserDefaults.standard.double(
            forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusWidthOffsetKey
        )
        let resolvedOffset = UserDefaults.standard.object(
            forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.plusWidthOffsetKey
        ) == nil ? TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultPlusWidthOffset : offset
        return max(config.iconSize + 4, base + CGFloat(resolvedOffset))
        #else
        return base
        #endif
    }

    private var dropdownWidth: CGFloat {
        let base = TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownWidth(config: config)
        #if DEBUG
        let offset = UserDefaults.standard.double(
            forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretWidthOffsetKey
        )
        let resolvedOffset = UserDefaults.standard.object(
            forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.caretWidthOffsetKey
        ) == nil ? TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultCaretWidthOffset : offset
        return max(
            TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownIconSize(config: config) + 4,
            base + CGFloat(resolvedOffset)
        )
        #else
        return base
        #endif
    }

    private func setHovered(_ segment: TitlebarNewWorkspaceCloudSplitButtonSegment, hovering: Bool) {
        guard titlebarControlsShouldTrackButtonHover(config: config) else { return }
        if hovering {
            hoveredSegment = segment
        } else if hoveredSegment == segment {
            hoveredSegment = nil
        }
        refreshButtonHoverState()
    }

    private func refreshConfiguration() {
        newTabButton.config = config
        cloudMenuButton.config = config
        refreshButtonHoverState()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func refreshButtonHoverState() {
        let groupIsHovering = hoveredSegment != nil || debugAlwaysHover
        newTabButton.groupIsHovering = groupIsHovering
        cloudMenuButton.groupIsHovering = groupIsHovering
        newTabButton.forceActiveHover = debugForcesHover(.newTab)
        cloudMenuButton.forceActiveHover = debugForcesHover(.cloudMenu)
    }

    private var debugAlwaysHover: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.alwaysHoverKey)
        #else
        false
        #endif
    }

    private func debugForcesHover(_ segment: TitlebarNewWorkspaceCloudSplitButtonSegment) -> Bool {
        #if DEBUG
        guard debugAlwaysHover else { return false }
        let rawValue = UserDefaults.standard.string(
            forKey: TitlebarNewWorkspaceCloudSplitButtonDebugSettings.forcedHoverSegmentKey
        ) ?? TitlebarNewWorkspaceCloudSplitButtonDebugSettings.defaultForcedHoverSegment.rawValue
        return TitlebarNewWorkspaceCloudSplitButtonForcedHoverSegment.stored(rawValue: rawValue)
            .includes(segment)
        #else
        return false
        #endif
    }

    @objc private func createWorkspace(_ sender: Any?) {
        #if DEBUG
        cmuxDebugLog("titlebar.newTab")
        #endif
        onNewTab()
    }

    @objc private func showWorkspaceMenu(_ sender: Any?) {
        if AppDelegate.shared?.showNewWorkspaceContextMenu(
            anchorView: cloudMenuButton,
            debugSource: "titlebar.newWorkspace.cloudMenu"
        ) != true {
            _ = AppDelegate.shared?.performCloudVMAction(
                debugSource: "titlebar.newWorkspace.cloudMenu.fallback"
            )
        }
    }
}

enum TitlebarCloudVMButton {
    @MainActor
    static func showCloudVMMenu(anchorView: NSView, event: NSEvent) {
        guard CmuxFeatureFlags.shared.isCloudVMUIEnabled else { return }
        NSMenu.popUpContextMenu(makeCloudVMMenu(), with: event, for: anchorView)
    }

    @MainActor
    static func showCloudVMMenu(anchorView: NSView) {
        guard CmuxFeatureFlags.shared.isCloudVMUIEnabled else { return }
        makeCloudVMMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
    }

    @MainActor
    static func makeCloudVMMenu() -> NSMenu {
        let menu = NSMenu()
        appendCloudVMMenuItems(to: menu)
        return menu
    }

    @MainActor
    static func appendCloudVMMenuItems(to menu: NSMenu) {
        menu.addItem(mouseDownMenuItem(
            title: String(localized: "command.cloudVM.open.title", defaultValue: "Open Base"),
            action: { CloudVMMenuTarget.shared.open() }
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.fork.title", defaultValue: "Fork Cloud VM"),
            action: #selector(CloudVMMenuTarget.fork)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Cloud VM"),
            action: #selector(CloudVMMenuTarget.snapshot)
        ))
        menu.addItem(menuItem(
            title: String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Checkpoint..."),
            action: #selector(CloudVMMenuTarget.restore)
        ))
        menu.addItem(.separator())
        menu.addItem(advancedMenuItem())
    }

    @MainActor
    private static func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = CloudVMMenuTarget.shared
        return item
    }

    @MainActor
    private static func mouseDownMenuItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = menuItem(title: title, action: #selector(CloudVMMenuTarget.open))
        item.view = MouseDownMenuItemView(title: title, action: action)
        return item
    }

    @MainActor
    private static func advancedMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "command.cloudVM.advanced.title", defaultValue: "Advanced"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.status.title", defaultValue: "Status"),
            action: #selector(CloudVMMenuTarget.status)
        ))
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.ports.title", defaultValue: "Ports"),
            action: #selector(CloudVMMenuTarget.ports)
        ))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote to Template"),
            action: #selector(CloudVMMenuTarget.promoteTemplate)
        ))
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Tools"),
            action: #selector(CloudVMMenuTarget.tools)
        ))
        submenu.addItem(menuItem(
            title: String(localized: "command.cloudVM.handoff.title", defaultValue: "Agent Handoff"),
            action: #selector(CloudVMMenuTarget.handoff)
        ))
        item.submenu = submenu
        return item
    }
}

@MainActor
private final class CloudVMMenuTarget: NSObject {
    static let shared = CloudVMMenuTarget()

    @objc func open() {
        _ = AppDelegate.shared?.performCloudVMAction(debugSource: "titlebar.cloudVM.menu.open")
    }

    @objc func fork() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.fork, debugSource: "titlebar.cloudVM.menu.fork")
    }

    @objc func snapshot() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.snapshot, debugSource: "titlebar.cloudVM.menu.snapshot")
    }

    @objc func restore() {
        _ = AppDelegate.shared?.performCloudVMRestoreCommand(debugSource: "titlebar.cloudVM.menu.restore")
    }

    @objc func promoteTemplate() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(
            .promoteTemplate,
            debugSource: "titlebar.cloudVM.menu.promoteTemplate"
        )
    }

    @objc func status() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.status, debugSource: "titlebar.cloudVM.menu.status")
    }

    @objc func ports() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.ports, debugSource: "titlebar.cloudVM.menu.ports")
    }

    @objc func tools() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.tools, debugSource: "titlebar.cloudVM.menu.tools")
    }

    @objc func handoff() {
        _ = AppDelegate.shared?.performCurrentCloudVMCommand(.handoff, debugSource: "titlebar.cloudVM.menu.handoff")
    }
}
