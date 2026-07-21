import AppKit
import Combine
import CmuxTestSupport
import SwiftUI

struct MinimalModeSidebarControlActionProxyView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig
    var isEnabled = true
    var requiresRevealedState = false
    let onAction: (MinimalModeSidebarControlActionSlot, NSView, NSPoint) -> Void

    func makeNSView(context: Context) -> MinimalModeSidebarControlActionView {
        let view = MinimalModeSidebarControlActionView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: MinimalModeSidebarControlActionView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: MinimalModeSidebarControlActionView) {
        view.config = config
        view.isEnabled = isEnabled
        view.requiresRevealedState = requiresRevealedState
        view.onAction = onAction
    }
}

enum TitlebarControlsHitRegions {
    static let outerLeadingPadding: CGFloat = HeaderChromeControlMetrics.titlebarControlsLeadingPadding
    static let buttonCount = MinimalModeSidebarControlActionSlot.allCases.count

    static func buttonXRanges(config: TitlebarControlsStyleConfig) -> [ClosedRange<CGFloat>] {
        MinimalModeSidebarControlActionSlot.allCases.compactMap {
            buttonXRange(for: $0, config: config)
        }
    }

    static func buttonXRange(
        for slot: MinimalModeSidebarControlActionSlot,
        config: TitlebarControlsStyleConfig
    ) -> ClosedRange<CGFloat>? {
        let startX = outerLeadingPadding + config.groupPadding.leading
        let sidebarX = startX
        let notificationsX = sidebarX + config.buttonSize + config.spacing
        let newTabX = notificationsX + config.buttonSize + config.spacing
        let newTabWidth = TitlebarNewWorkspaceCloudSplitButtonMetrics.primaryWidth(config: config)
        let cloudMenuX = newTabX + newTabWidth
        let cloudMenuWidth = TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownWidth(config: config)
        let focusBackX = cloudMenuX + cloudMenuWidth + config.spacing
        let focusForwardX = focusBackX + config.buttonSize + config.spacing

        let minX: CGFloat = switch slot {
        case .toggleSidebar:
            sidebarX
        case .showNotifications:
            notificationsX
        case .newTab:
            newTabX
        case .cloudVM:
            cloudMenuX
        case .focusHistoryBack:
            focusBackX
        case .focusHistoryForward:
            focusForwardX
        }
        let width: CGFloat = switch slot {
        case .newTab:
            newTabWidth
        case .cloudVM:
            cloudMenuWidth
        case .toggleSidebar, .showNotifications, .focusHistoryBack, .focusHistoryForward:
            config.buttonSize
        }
        return minX...(minX + width)
    }

    static func sidebarActionSlot(
        at point: NSPoint,
        config: TitlebarControlsStyleConfig
    ) -> MinimalModeSidebarControlActionSlot? {
        for (index, range) in buttonXRanges(config: config).enumerated() where range.contains(point.x) {
            return MinimalModeSidebarControlActionSlot(rawValue: index)
        }
        return nil
    }

    static func pointFallsInButtonColumn(_ point: NSPoint, config: TitlebarControlsStyleConfig) -> Bool {
        sidebarActionSlot(at: point, config: config) != nil
    }
}

final class MinimalModeSidebarControlActionView: NSView {
    var config = TitlebarControlsStyle.classic.config
    {
        didSet { needsLayout = true }
    }
    var isEnabled = true
    {
        didSet { syncButtons() }
    }
    var requiresRevealedState = false
    {
        didSet { syncButtons() }
    }
    var telemetryPrefix = "minimalSidebarClickProxy"
    var onAction: ((MinimalModeSidebarControlActionSlot, NSView, NSPoint) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private let buttons: [MinimalModeSidebarControlActionSlot: MinimalModeSidebarControlButton]

    override init(frame frameRect: NSRect) {
        var buttons: [MinimalModeSidebarControlActionSlot: MinimalModeSidebarControlButton] = [:]
        for slot in MinimalModeSidebarControlActionSlot.allCases {
            buttons[slot] = Self.makeButton(for: slot)
        }
        self.buttons = buttons
        super.init(frame: frameRect)
        for (slot, button) in buttons {
            button.target = self
            button.tag = slot.rawValue
            button.actionOwner = self
            button.setAccessibilityParent(self)
            addSubview(button)
        }
        observeRevealState()
        syncButtons()
    }

    required init?(coder: NSCoder) {
        var buttons: [MinimalModeSidebarControlActionSlot: MinimalModeSidebarControlButton] = [:]
        for slot in MinimalModeSidebarControlActionSlot.allCases {
            buttons[slot] = Self.makeButton(for: slot)
        }
        self.buttons = buttons
        super.init(coder: coder)
        for (slot, button) in buttons {
            button.target = self
            button.action = #selector(buttonPressed(_:))
            button.tag = slot.rawValue
            button.actionOwner = self
            button.setAccessibilityParent(self)
            addSubview(button)
        }
        observeRevealState()
        syncButtons()
    }

    private static func makeButton(for slot: MinimalModeSidebarControlActionSlot) -> MinimalModeSidebarControlButton {
        let button = MinimalModeSidebarControlButton(slot: slot)
        button.isBordered = false
        button.isTransparent = true
        button.title = ""
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.refusesFirstResponder = true
        button.setButtonType(.momentaryChange)
        button.action = #selector(buttonPressed(_:))
        button.identifier = NSUserInterfaceItemIdentifier(slot.accessibilityIdentifier)
        button.setAccessibilityIdentifier(slot.accessibilityIdentifier)
        button.setAccessibilityLabel(slot.accessibilityLabel)
        button.setAccessibilityRole(.button)
        return button
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func accessibilityChildren() -> [Any]? {
        guard isRevealed || !requiresRevealedState else { return [] }
        return MinimalModeSidebarControlActionSlot.allCases.compactMap { buttons[$0] }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let eventType = NSApp.currentEvent?.type,
           eventType != .leftMouseDown,
           eventType != .rightMouseDown {
            return nil
        }
        guard bounds.contains(point) else { return nil }
        guard let slot = TitlebarControlsHitRegions.sidebarActionSlot(at: point, config: config) else {
            return nil
        }
        if NSApp.currentEvent?.type == .rightMouseDown, !slot.acceptsContextMenu {
            return nil
        }
        guard shouldAcceptAction(at: point) else { return nil }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
            _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["\(telemetryPrefix)LastHitTestSlot"] = slot.debugName
                payload["\(telemetryPrefix)LastHitTestPoint"] = windowDragHandleFormatPoint(point)
                payload["\(telemetryPrefix)LastHitTestWindowNumber"] = window.map { String($0.windowNumber) } ?? "nil"
                payload["\(telemetryPrefix)LastHitTestRevealed"] = String(isRevealed)
            }
        }
        #endif
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard let slot = TitlebarControlsHitRegions.sidebarActionSlot(at: localPoint, config: config) else {
            super.mouseDown(with: event)
            return
        }
        guard shouldAcceptAction(at: localPoint) else {
            super.mouseDown(with: event)
            return
        }
        performAction(slot: slot, anchorView: self, locationInWindow: event.locationInWindow)
    }

    override func rightMouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard let slot = TitlebarControlsHitRegions.sidebarActionSlot(at: localPoint, config: config),
              shouldAcceptAction(at: localPoint) else {
            super.rightMouseDown(with: event)
            return
        }
        switch slot {
        case .toggleSidebar:
            CmuxExtensionSidebarSelection.showMenu(anchorView: self, event: event)
        case .newTab:
            _ = AppDelegate.shared?.showNewWorkspaceContextMenu(anchorView: self, event: event)
        case .cloudVM:
            _ = AppDelegate.shared?.showNewWorkspaceContextMenu(
                anchorView: self,
                event: event,
                debugSource: "titlebar.minimalSidebar.cloudMenu.rightClick"
            )
        case .focusHistoryBack:
            _ = AppDelegate.shared?.showFocusHistoryContextMenu(anchorView: self, event: event, direction: .back)
        case .focusHistoryForward:
            _ = AppDelegate.shared?.showFocusHistoryContextMenu(anchorView: self, event: event, direction: .forward)
        case .showNotifications:
            super.rightMouseDown(with: event)
        }
    }

    override func layout() {
        super.layout()
        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
        for (index, range) in ranges.enumerated() {
            guard let slot = MinimalModeSidebarControlActionSlot(rawValue: index),
                  let button = buttons[slot] else { continue }
            button.frame = NSRect(
                x: range.lowerBound,
                y: max(0, (bounds.height - config.buttonSize) / 2),
                width: range.upperBound - range.lowerBound,
                height: config.buttonSize
            )
        }
        syncButtons()
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let sender = sender as? MinimalModeSidebarControlButton else { return }
        performButtonAction(sender)
    }

    fileprivate func performButtonAction(_ sender: MinimalModeSidebarControlButton) {
        let localPoint = sender.frame.center
        performAction(slot: sender.slot, anchorView: sender, locationInWindow: convert(localPoint, to: nil))
    }

    private func performAction(
        slot: MinimalModeSidebarControlActionSlot,
        anchorView: NSView,
        locationInWindow: NSPoint
    ) {
        guard isEnabled else { return }

        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
            _ = UITestCaptureSink().mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["\(telemetryPrefix)LastAction"] = slot.debugName
                payload["\(telemetryPrefix)LastPoint"] = windowDragHandleFormatPoint(convert(locationInWindow, from: nil))
                payload["\(telemetryPrefix)WindowNumber"] = window.map { String($0.windowNumber) } ?? "nil"
                payload["\(telemetryPrefix)LastActionRevealed"] = String(isRevealed)
            }
        }
        #endif

        if let window {
            MinimalModeSidebarChromeHoverState.shared.setHovering(true, windowNumber: window.windowNumber)
        }
        onAction?(slot, anchorView, locationInWindow)
    }

    private func observeRevealState() {
        MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumberPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncButtons() }
            .store(in: &cancellables)

        NotificationsPopoverVisibilityState.shared.shownWindowNumbersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncButtons() }
            .store(in: &cancellables)
    }

    private func syncButtons() {
        let revealed = isRevealed
        for button in buttons.values {
            button.isEnabled = isEnabled && (revealed || !requiresRevealedState)
            button.setAccessibilityElement(revealed || !requiresRevealedState)
        }
    }

    private var isRevealed: Bool {
        guard isEnabled else { return false }
        guard requiresRevealedState else { return true }
        guard let window else { return false }
        return MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber == window.windowNumber
            || NotificationsPopoverVisibilityState.shared.isShown(in: window.windowNumber)
    }

    private func shouldAcceptAction(at localPoint: NSPoint) -> Bool {
        guard isEnabled else { return false }
        guard requiresRevealedState else { return true }
        return isRevealed
    }
}

private final class MinimalModeSidebarControlButton: NSButton {
    let slot: MinimalModeSidebarControlActionSlot
    weak var actionOwner: MinimalModeSidebarControlActionView?

    init(slot: MinimalModeSidebarControlActionSlot) {
        self.slot = slot
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityIdentifier() -> String {
        slot.accessibilityIdentifier
    }

    override func accessibilityLabel() -> String? {
        slot.accessibilityLabel
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        actionOwner?.performButtonAction(self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        actionOwner?.performButtonAction(self)
        return true
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
