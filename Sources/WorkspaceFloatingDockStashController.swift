import AppKit
import CmuxAppKitSupportUI
import QuartzCore

struct WorkspaceFloatingDockStashItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let symbolName: String
    let stashedAt: TimeInterval
}

enum WorkspaceFloatingDockStashLayout {
    static let directItemLimit = 3
    static let railWidth: CGFloat = 28
    static let slotHeight: CGFloat = 40
    static let railPadding: CGFloat = 4
    static let screenBottomInset: CGFloat = 24
    static let trayWidth: CGFloat = 280
    static let trayRowHeight: CGFloat = 42
    static let maximumTrayRows = 7
    static let restingVisibleFraction: CGFloat = 0.5

    static func railFrame(
        visibleScreenFrame: CGRect,
        itemCount: Int,
        isRevealed: Bool = false
    ) -> CGRect? {
        guard itemCount > 0 else { return nil }
        let directCount = min(itemCount, directItemLimit)
        let slotCount = directCount + (itemCount > directItemLimit ? 1 : 0)
        let height = railPadding * 2 + CGFloat(slotCount) * slotHeight
        let visibleWidth = isRevealed ? railWidth : railWidth * restingVisibleFraction
        return CGRect(
            x: visibleScreenFrame.maxX - visibleWidth,
            y: visibleScreenFrame.minY + screenBottomInset,
            width: railWidth,
            height: height
        )
    }

    static func trayFrame(visibleScreenFrame: CGRect, railFrame: CGRect, itemCount: Int) -> CGRect {
        let visibleRows = min(max(1, itemCount), maximumTrayRows)
        let height = railPadding * 2 + CGFloat(visibleRows) * trayRowHeight
        let unclampedY = railFrame.minY
        return CGRect(
            x: railFrame.minX - trayWidth - 8,
            y: min(max(unclampedY, visibleScreenFrame.minY + 8), visibleScreenFrame.maxY - height - 8),
            width: trayWidth,
            height: height
        )
    }

    /// Keeps Bonsplit at its live size while sliding the window almost entirely
    /// beyond the right edge. The edge rail replaces the remaining sliver once
    /// the animation completes.
    static func offscreenWindowFrame(
        windowFrame: CGRect,
        targetFrame: CGRect,
        visibleScreenFrame: CGRect
    ) -> CGRect {
        let y: CGFloat
        if windowFrame.height >= visibleScreenFrame.height {
            y = visibleScreenFrame.minY
        } else {
            y = min(
                max(targetFrame.midY - windowFrame.height / 2, visibleScreenFrame.minY),
                visibleScreenFrame.maxY - windowFrame.height
            )
        }
        return CGRect(
            x: visibleScreenFrame.maxX - 12,
            y: y,
            width: windowFrame.width,
            height: windowFrame.height
        )
    }
}

@MainActor
final class WorkspaceFloatingDockStashController {
    private weak var parentWindow: NSWindow?
    private let railPanel: NSPanel
    private let trayPanel: NSPanel
    private let railView = WorkspaceFloatingDockStashRailView()
    private let trayView = WorkspaceFloatingDockStashTrayView()
    private let railGlass = WindowGlassEffect()
    private let trayGlass = WindowGlassEffect()
    private var items: [WorkspaceFloatingDockStashItem] = []
    private var onRestore: ((UUID) -> Void)?
    private var isTrayVisible = false
    private var isPointerOverRail = false
    private var isRailRevealed = false
    private var parentObservers: [NSObjectProtocol] = []

    init(parentWindow: NSWindow) {
        self.parentWindow = parentWindow
        railPanel = Self.makePanel(
            identifier: "cmux.workspace.float.stashRail",
            contentView: railView
        )
        trayPanel = Self.makePanel(
            identifier: "cmux.workspace.float.stashTray",
            contentView: trayView
        )

        railGlass.changesTintWithWindowKeyState = false
        trayGlass.changesTintWithWindowKeyState = false
        applyGlass()
        railView.onHoverChange = { [weak self] isHovering in
            guard let self else { return }
            self.isPointerOverRail = isHovering
            self.setRailRevealed(isHovering || self.isTrayVisible)
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            parentObservers.append(center.addObserver(
                forName: name,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reposition()
                }
            })
        }
    }

    deinit {
        let center = NotificationCenter.default
        parentObservers.forEach(center.removeObserver)
    }

    func update(
        items: [WorkspaceFloatingDockStashItem],
        onRestore: @escaping (UUID) -> Void
    ) {
        let sortedItems = items.sorted {
            if $0.stashedAt == $1.stashedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.stashedAt > $1.stashedAt
        }
        self.onRestore = onRestore
        guard sortedItems != self.items else {
            if sortedItems.isEmpty {
                hide()
            } else {
                reposition()
            }
            return
        }
        self.items = sortedItems

        guard !self.items.isEmpty else {
            hide()
            return
        }

        railView.update(
            items: Array(self.items.prefix(WorkspaceFloatingDockStashLayout.directItemLimit)),
            overflowCount: max(0, self.items.count - WorkspaceFloatingDockStashLayout.directItemLimit),
            onRestore: onRestore,
            onToggleOverflow: { [weak self] in self?.toggleTray() }
        )
        trayView.update(items: self.items) { [weak self] dockID in
            self?.setTrayVisible(false)
            self?.onRestore?(dockID)
        }
        reposition()
        attachAndOrderFront(railPanel)
        if isTrayVisible {
            attachAndOrderFront(trayPanel)
        }
    }

    func animationTargetFrame(for dockID: UUID) -> CGRect? {
        railView.animationTargetFrame(for: dockID, in: railPanel)
            ?? railView.overflowAnimationTargetFrame(in: railPanel)
            ?? (railPanel.isVisible ? railPanel.frame : nil)
    }

    func visibleScreenFrame() -> CGRect? {
        parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    }

    func reconcileScreenConfiguration() {
        reposition()
    }

    func owns(window: NSWindow) -> Bool {
        window === railPanel || window === trayPanel
    }

    func teardown() {
        hide()
        railGlass.remove(from: railPanel)
        trayGlass.remove(from: trayPanel)
    }

    private func toggleTray() {
        setTrayVisible(!isTrayVisible)
    }

    private func setTrayVisible(_ visible: Bool) {
        guard visible != isTrayVisible else { return }
        isTrayVisible = visible
        guard visible, !items.isEmpty else {
            detachAndOrderOut(trayPanel)
            setRailRevealed(isPointerOverRail)
            return
        }
        setRailRevealed(true)
        reposition()
        attachAndOrderFront(trayPanel)
    }

    private func setRailRevealed(_ revealed: Bool) {
        guard revealed != isRailRevealed else { return }
        isRailRevealed = revealed
        reposition(animated: true)
    }

    private func reposition(animated: Bool = false) {
        guard let screenFrame = visibleScreenFrame(),
              let railFrame = WorkspaceFloatingDockStashLayout.railFrame(
                visibleScreenFrame: screenFrame,
                itemCount: items.count,
                isRevealed: isRailRevealed
              ) else { return }
        if animated,
           railPanel.isVisible,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.0,
                    0.0,
                    0.2,
                    1.0
                )
                railPanel.animator().setFrame(railFrame, display: true)
            }
        } else {
            railPanel.setFrame(railFrame, display: railPanel.isVisible)
        }
        railView.frame = NSRect(origin: .zero, size: railFrame.size)
        railView.needsLayout = true
        railView.layoutSubtreeIfNeeded()

        let trayFrame = WorkspaceFloatingDockStashLayout.trayFrame(
            visibleScreenFrame: screenFrame,
            railFrame: railFrame,
            itemCount: items.count
        )
        trayPanel.setFrame(trayFrame, display: trayPanel.isVisible)
        trayView.frame = NSRect(origin: .zero, size: trayFrame.size)
        trayView.needsLayout = true
        trayView.layoutSubtreeIfNeeded()
    }

    private func hide() {
        isTrayVisible = false
        isPointerOverRail = false
        isRailRevealed = false
        detachAndOrderOut(trayPanel)
        detachAndOrderOut(railPanel)
    }

    private func attachAndOrderFront(_ panel: NSPanel) {
        guard let parentWindow else { return }
        if panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func detachAndOrderOut(_ panel: NSPanel) {
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }

    private func applyGlass() {
        let appearance = WorkspaceFloatingDockBackdropAppearance.raycast(
            backgroundColor: GhosttyBackgroundTheme.currentColor()
        )
        for (glass, panel) in [(railGlass, railPanel), (trayGlass, trayPanel)] {
            glass.backgroundOpacity = appearance.opacity
            glass.apply(
                to: panel,
                tintColor: appearance.tintColor,
                style: appearance.liquidGlassStyle ?? .regular
            )
        }
    }

    private static func makePanel(identifier: String, contentView: NSView) -> NSPanel {
        let panel = WorkspaceFloatingDockStashPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = contentView
        return panel
    }
}

private final class WorkspaceFloatingDockStashPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class WorkspaceFloatingDockStashRailView: NSView {
    private let stack = NSStackView()
    private var itemButtons: [UUID: NSButton] = [:]
    private weak var overflowButton: NSButton?
    private var hoverTrackingArea: NSTrackingArea?
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: WorkspaceFloatingDockStashLayout.railPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -WorkspaceFloatingDockStashLayout.railPadding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityIdentifier("WorkspaceFloatingDockStashRail")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    func update(
        items: [WorkspaceFloatingDockStashItem],
        overflowCount: Int,
        onRestore: @escaping (UUID) -> Void,
        onToggleOverflow: @escaping () -> Void
    ) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        itemButtons.removeAll(keepingCapacity: true)
        overflowButton = nil

        for item in items {
            let button = WorkspaceFloatingDockStashButton(
                symbolName: item.symbolName,
                title: item.title,
                identifier: "WorkspaceFloatingDockStashItem.\(item.id.uuidString)"
            ) {
                onRestore(item.id)
            }
            itemButtons[item.id] = button
            addSlot(button)
        }
        if overflowCount > 0 {
            let title = String(
                format: String(
                    localized: "floatingDock.stash.overflowHelp",
                    defaultValue: "Show %lld more stashed windows"
                ),
                locale: .current,
                Int64(overflowCount)
            )
            let button = WorkspaceFloatingDockStashButton(
                text: "+\(overflowCount)",
                title: title,
                identifier: "WorkspaceFloatingDockStashOverflow"
            ) {
                onToggleOverflow()
            }
            overflowButton = button
            addSlot(button)
        }
    }

    func animationTargetFrame(for dockID: UUID, in panel: NSPanel) -> CGRect? {
        itemButtons[dockID].map { screenFrame(of: $0, in: panel) }
    }

    func overflowAnimationTargetFrame(in panel: NSPanel) -> CGRect? {
        overflowButton.map { screenFrame(of: $0, in: panel) }
    }

    private func addSlot(_ button: NSButton) {
        stack.addArrangedSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: WorkspaceFloatingDockStashLayout.railWidth),
            button.heightAnchor.constraint(equalToConstant: WorkspaceFloatingDockStashLayout.slotHeight),
        ])
    }

    private func screenFrame(of view: NSView, in panel: NSPanel) -> CGRect {
        layoutSubtreeIfNeeded()
        return panel.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private final class WorkspaceFloatingDockStashTrayView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = WorkspaceFloatingDockStashDocumentView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: WorkspaceFloatingDockStashLayout.railPadding),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -WorkspaceFloatingDockStashLayout.railPadding),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: WorkspaceFloatingDockStashLayout.railPadding),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -WorkspaceFloatingDockStashLayout.railPadding),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
        ])
        setAccessibilityIdentifier("WorkspaceFloatingDockStashTray")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [WorkspaceFloatingDockStashItem], onRestore: @escaping (UUID) -> Void) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in items {
            let button = WorkspaceFloatingDockStashRowButton(item: item) {
                onRestore(item.id)
            }
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalTo: stack.widthAnchor),
                button.heightAnchor.constraint(equalToConstant: WorkspaceFloatingDockStashLayout.trayRowHeight),
            ])
        }
    }
}

private final class WorkspaceFloatingDockStashDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class WorkspaceFloatingDockStashButton: NSButton {
    private let onPress: () -> Void

    init(
        symbolName: String? = nil,
        text: String? = nil,
        title: String,
        identifier: String,
        onPress: @escaping () -> Void
    ) {
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        imagePosition = symbolName == nil ? .noImage : .imageOnly
        image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        self.title = text ?? ""
        font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        contentTintColor = .secondaryLabelColor
        toolTip = title
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityLabel(title)
        target = self
        action = #selector(press(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press(_ sender: Any?) {
        onPress()
    }
}

private final class WorkspaceFloatingDockStashRowButton: NSButton {
    private let onPress: () -> Void

    init(item: WorkspaceFloatingDockStashItem, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)
        imagePosition = .imageLeading
        imageHugsTitle = true
        title = item.title
        alignment = .left
        font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = .labelColor
        toolTip = item.title
        identifier = NSUserInterfaceItemIdentifier(
            "WorkspaceFloatingDockStashTrayItem.\(item.id.uuidString)"
        )
        setAccessibilityLabel(item.title)
        target = self
        action = #selector(press(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func press(_ sender: Any?) {
        onPress()
    }
}
