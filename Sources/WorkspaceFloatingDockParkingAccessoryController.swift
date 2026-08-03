import AppKit
import CmuxAppKitSupportUI
import QuartzCore

enum WorkspaceFloatingDockParkingReorderPhase {
    case began
    case changed
    case ended
}

/// Owns the compact glass name and reorder accessory shown beside a parked
/// workspace floating window.
@MainActor
final class WorkspaceFloatingDockParkingAccessoryController {
    static let height: CGFloat = 44
    static let gap: CGFloat = 10

    private let panel: WorkspaceFloatingDockParkingAccessoryPanel
    private let accessoryView: WorkspaceFloatingDockParkingAccessoryView
    private let glassEffect = WindowGlassEffect()
    private var presentationGeneration = 0
    private var anchorFrame: CGRect?
    private var parkingEdge: WorkspaceFloatingDockParkingEdge = .trailing
    private(set) var isEditing = false

    var window: NSWindow { panel }
    var isVisible: Bool { panel.isVisible }

    init(
        dockID: UUID,
        onRestore: @escaping () -> Void,
        onRename: @escaping (String) -> Bool,
        onReorderDrag: @escaping (
            WorkspaceFloatingDockParkingReorderPhase,
            NSPoint
        ) -> Void,
        onReorderStep: @escaping (Int) -> Void,
        onEditingEnded: @escaping () -> Void
    ) {
        accessoryView = WorkspaceFloatingDockParkingAccessoryView(
            dockID: dockID,
            onRestore: onRestore,
            onRename: onRename,
            onReorderDrag: onReorderDrag,
            onReorderStep: onReorderStep,
            onEditingChange: { _ in },
            onEditingEnded: onEditingEnded
        )
        panel = WorkspaceFloatingDockParkingAccessoryPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: accessoryView.preferredWidth,
                height: Self.height
            ),
            // Hover presentation uses orderFront without taking focus. Rename
            // explicitly makes this key, matching the command palette's stable
            // keyable child-panel lifecycle.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier(
            "cmux.workspace.float.parkingAccessory.\(dockID.uuidString)"
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = accessoryView

        accessoryView.onEditingChange = { [weak self] isEditing in
            self?.isEditing = isEditing
        }
        accessoryView.onBeginRename = { [weak self] in
            self?.beginRenaming()
        }
        glassEffect.changesTintWithWindowKeyState = false
    }

    func show(
        attachedTo ownerWindow: NSWindow,
        title: String,
        anchorFrame: CGRect,
        parkingEdge: WorkspaceFloatingDockParkingEdge,
        appearance: WorkspaceFloatingDockBackdropAppearance,
        animated: Bool
    ) {
        presentationGeneration &+= 1
        self.anchorFrame = anchorFrame
        self.parkingEdge = parkingEdge
        accessoryView.updateTitle(title)
        applyAppearance(appearance)
        attach(to: ownerWindow)
        let targetFrame = frame(
            anchorFrame: anchorFrame,
            width: accessoryView.preferredWidth,
            parkingEdge: parkingEdge
        )

        guard !panel.isVisible else {
            setFrame(targetFrame, animated: animated)
            panel.alphaValue = 1
            panel.orderFront(nil)
            return
        }

        panel.alphaValue = animated ? 0 : 1
        var initialFrame = targetFrame
        if animated {
            initialFrame.origin.x += inwardHorizontalOffset(for: parkingEdge, distance: 10)
        }
        panel.setFrame(initialFrame, display: false)
        panel.orderFront(nil)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.0,
                0.0,
                0.2,
                1.0
            )
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func update(
        title: String,
        attachedTo ownerWindow: NSWindow,
        anchorFrame: CGRect,
        parkingEdge: WorkspaceFloatingDockParkingEdge,
        appearance: WorkspaceFloatingDockBackdropAppearance,
        animated: Bool
    ) {
        guard panel.isVisible else { return }
        self.anchorFrame = anchorFrame
        self.parkingEdge = parkingEdge
        accessoryView.updateTitle(title)
        applyAppearance(appearance)
        attach(to: ownerWindow)
        setFrame(
            frame(
                anchorFrame: anchorFrame,
                width: accessoryView.preferredWidth,
                parkingEdge: parkingEdge
            ),
            animated: animated
        )
    }

    func beginRenaming() {
        guard panel.isVisible, let anchorFrame else { return }
        presentationGeneration &+= 1
        accessoryView.beginRenaming()
        let targetFrame = frame(
            anchorFrame: anchorFrame,
            width: accessoryView.preferredWidth,
            parkingEdge: parkingEdge
        )
        setFrame(targetFrame, animated: true)
        panel.makeKeyAndOrderFront(nil)
        let focused = accessoryView.focusRenameField()
#if DEBUG
        cmuxDebugLog(
            "floating.rename.focus result=\(focused ? 1 : 0) " +
            "key=\(panel.isKeyWindow ? 1 : 0) " +
            "firstResponder=\(String(describing: panel.firstResponder)) " +
            "editor=\(String(describing: accessoryView.renameField.currentEditor()))"
        )
#endif
    }

    func hide(animated: Bool) {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        accessoryView.cancelRenaming(notify: false)
        isEditing = false
        guard panel.isVisible else {
            detach()
            return
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            detach()
            return
        }
        var targetFrame = panel.frame
        targetFrame.origin.x += inwardHorizontalOffset(for: parkingEdge, distance: 8)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.detach()
        }
    }

    func contains(_ screenPoint: NSPoint, tolerance: CGFloat = 10) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(screenPoint)
    }

    func teardown() {
        presentationGeneration &+= 1
        accessoryView.cancelRenaming(notify: false)
        glassEffect.remove(from: panel)
        panel.orderOut(nil)
        detach()
    }

    private func applyAppearance(_ appearance: WorkspaceFloatingDockBackdropAppearance) {
        glassEffect.remove(from: panel)
        glassEffect.backgroundOpacity = appearance.opacity
        glassEffect.apply(
            to: panel,
            tintColor: appearance.tintColor,
            style: appearance.liquidGlassStyle ?? .regular
        )
        // The compatibility blur lives in the content theme frame on older
        // macOS versions, while native glass becomes the content root. Round
        // both hosts so the accessory keeps the same silhouette on either path.
        [panel.contentView, panel.contentView?.superview]
            .compactMap { $0 }
            .forEach { view in
                view.wantsLayer = true
                view.layer?.cornerRadius = 14
                view.layer?.cornerCurve = .continuous
                view.layer?.masksToBounds = true
            }
    }

    private func attach(to ownerWindow: NSWindow) {
        if let currentParent = panel.parent, currentParent !== ownerWindow {
            currentParent.removeChildWindow(panel)
        }
        if panel.parent !== ownerWindow {
            ownerWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func detach() {
        panel.parent?.removeChildWindow(panel)
        anchorFrame = nil
    }

    private func frame(
        anchorFrame: CGRect,
        width: CGFloat,
        parkingEdge: WorkspaceFloatingDockParkingEdge
    ) -> CGRect {
        let minX: CGFloat = switch parkingEdge {
        case .leading:
            anchorFrame.maxX + Self.gap
        case .trailing:
            anchorFrame.minX - Self.gap - width
        }
        return CGRect(
            x: minX,
            y: anchorFrame.midY - (Self.height / 2),
            width: width,
            height: Self.height
        )
    }

    private func inwardHorizontalOffset(
        for parkingEdge: WorkspaceFloatingDockParkingEdge,
        distance: CGFloat
    ) -> CGFloat {
        switch parkingEdge {
        case .leading:
            -distance
        case .trailing:
            distance
        }
    }

    private func setFrame(_ frame: CGRect, animated: Bool) {
        guard panel.frame != frame else { return }
        guard animated, panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: panel.isVisible)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.0,
                0.0,
                0.2,
                1.0
            )
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private final class WorkspaceFloatingDockParkingAccessoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class WorkspaceFloatingDockParkingAccessoryView: NSView {
    private static let horizontalPadding: CGFloat = 8
    private static let gripWidth: CGFloat = 26
    private static let buttonWidth: CGFloat = 28
    private static let interitemSpacing: CGFloat = 4
    private static let minimumWidth: CGFloat = 170
    private static let maximumWidth: CGFloat = 320
    private static let editingWidth: CGFloat = 320

    private let titleLabel = NSTextField(labelWithString: "")
    fileprivate let renameField = NSTextField()
    private let grip: WorkspaceFloatingDockParkingGrip
    private let renameButton = WorkspaceFloatingDockParkingAccessoryButton()
    private let restoreButton = WorkspaceFloatingDockParkingAccessoryButton()
    private let onRename: (String) -> Bool
    private let onEditingEnded: () -> Void
    private var renameCoordinator: SidebarInlineRenameCoordinator?
    private var isRenaming = false
    private var title = ""
    var onEditingChange: (Bool) -> Void
    var onBeginRename: (() -> Void)?

    var preferredWidth: CGFloat {
        if isRenaming { return Self.editingWidth }
        let measuredTitleWidth = ceil((title as NSString).size(
            withAttributes: [.font: titleLabel.font ?? NSFont.systemFont(ofSize: 13)]
        ).width)
        let chromeWidth = (Self.horizontalPadding * 2)
            + Self.gripWidth
            + (Self.buttonWidth * 2)
            + (Self.interitemSpacing * 3)
        return min(
            Self.maximumWidth,
            max(Self.minimumWidth, measuredTitleWidth + chromeWidth)
        )
    }

    init(
        dockID: UUID,
        onRestore: @escaping () -> Void,
        onRename: @escaping (String) -> Bool,
        onReorderDrag: @escaping (
            WorkspaceFloatingDockParkingReorderPhase,
            NSPoint
        ) -> Void,
        onReorderStep: @escaping (Int) -> Void,
        onEditingChange: @escaping (Bool) -> Void,
        onEditingEnded: @escaping () -> Void
    ) {
        self.onRename = onRename
        self.onEditingChange = onEditingChange
        self.onEditingEnded = onEditingEnded
        grip = WorkspaceFloatingDockParkingGrip(
            dockID: dockID,
            onDrag: onReorderDrag,
            onStep: onReorderStep
        )
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.minimumWidth,
            height: WorkspaceFloatingDockParkingAccessoryController.height
        ))

        autoresizingMask = [.width, .height]
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setAccessibilityIdentifier(
            "FloatingWindowParkingName.\(dockID.uuidString)"
        )

        renameField.font = .systemFont(ofSize: 13, weight: .medium)
        renameField.isBezeled = false
        renameField.isBordered = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.isHidden = true
        renameField.setAccessibilityIdentifier(
            "FloatingWindowRenameField.\(dockID.uuidString)"
        )
        renameField.setAccessibilityLabel(String(
            localized: "floatingDock.parking.nameField",
            defaultValue: "Floating Window Name"
        ))

        configure(
            renameButton,
            symbol: "pencil",
            label: String(
                localized: "floatingDock.parking.rename",
                defaultValue: "Rename Floating Window"
            ),
            action: #selector(renamePressed)
        )
        configure(
            restoreButton,
            symbol: "arrow.uturn.backward",
            label: String(
                localized: "floatingDock.parking.restore",
                defaultValue: "Restore Floating Window"
            ),
            action: #selector(restorePressed)
        )
        restoreButton.onPress = onRestore

        addSubview(grip)
        addSubview(titleLabel)
        addSubview(renameField)
        addSubview(renameButton)
        addSubview(restoreButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let controlY = floor((height - Self.buttonWidth) / 2)
        grip.frame = CGRect(
            x: Self.horizontalPadding,
            y: controlY,
            width: Self.gripWidth,
            height: Self.buttonWidth
        )
        restoreButton.frame = CGRect(
            x: bounds.maxX - Self.horizontalPadding - Self.buttonWidth,
            y: controlY,
            width: Self.buttonWidth,
            height: Self.buttonWidth
        )
        renameButton.frame = CGRect(
            x: restoreButton.frame.minX - Self.interitemSpacing - Self.buttonWidth,
            y: controlY,
            width: Self.buttonWidth,
            height: Self.buttonWidth
        )
        let titleMinX = grip.frame.maxX + Self.interitemSpacing
        let titleMaxX = (isRenaming ? restoreButton : renameButton).frame.minX
            - Self.interitemSpacing
        let titleFrame = CGRect(
            x: titleMinX,
            y: floor((height - 22) / 2),
            width: max(0, titleMaxX - titleMinX),
            height: 22
        )
        titleLabel.frame = titleFrame
        renameField.frame = titleFrame
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func updateTitle(_ title: String) {
        self.title = title
        titleLabel.stringValue = title
        grip.updateTitle(title)
        needsLayout = true
    }

    func beginRenaming() {
        guard !isRenaming else { return }
        isRenaming = true
        renameField.stringValue = title
        titleLabel.isHidden = true
        renameButton.isHidden = true
        renameField.isHidden = false
        let coordinator = SidebarInlineRenameCoordinator(
            onCommit: { [weak self] draft in
                self?.commitRenaming(draft)
            },
            onCancel: { [weak self] in
                self?.finishRenaming()
            }
        )
        renameCoordinator = coordinator
        renameField.delegate = coordinator
        onEditingChange(true)
        needsLayout = true
    }

    @discardableResult
    fileprivate func focusRenameField() -> Bool {
        guard isRenaming, let window else { return false }
        if let editor = renameField.currentEditor() {
            editor.selectAll(nil)
            return true
        }
        let focused = window.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
        return focused
    }

    func cancelRenaming(notify: Bool = true) {
        guard isRenaming else { return }
        renameCoordinator = nil
        renameField.delegate = nil
        finishRenaming(notify: notify)
    }

    private func commitRenaming(_ draft: String) {
        guard WorkspaceFloatingDock.normalizedTitle(draft) != nil,
              onRename(draft) else {
            NSSound.beep()
            renameCoordinator = nil
            renameField.delegate = nil
            isRenaming = false
            beginRenaming()
            return
        }
        updateTitle(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        finishRenaming()
    }

    private func finishRenaming(notify: Bool = true) {
        guard isRenaming else { return }
        isRenaming = false
        renameCoordinator = nil
        renameField.delegate = nil
        renameField.isHidden = true
        titleLabel.isHidden = false
        renameButton.isHidden = false
        onEditingChange(false)
        needsLayout = true
        if notify {
            onEditingEnded()
        }
    }

    private func configure(
        _ button: WorkspaceFloatingDockParkingAccessoryButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        button.image?.isTemplate = true
        button.contentTintColor = .secondaryLabelColor
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.toolTip = label
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    @objc private func renamePressed() {
        onBeginRename?()
    }

    @objc private func restorePressed() {
        restoreButton.onPress?()
    }
}

private final class WorkspaceFloatingDockParkingAccessoryButton: NSButton {
    var onPress: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class WorkspaceFloatingDockParkingGrip: NSControl {
    private let onDrag: (
        WorkspaceFloatingDockParkingReorderPhase,
        NSPoint
    ) -> Void
    private let onStep: (Int) -> Void
    private var isDragging = false
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(
        dockID: UUID,
        onDrag: @escaping (
            WorkspaceFloatingDockParkingReorderPhase,
            NSPoint
        ) -> Void,
        onStep: @escaping (Int) -> Void
    ) {
        self.onDrag = onDrag
        self.onStep = onStep
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(
            "FloatingWindowParkingReorderGrip.\(dockID.uuidString)"
        )
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func updateTitle(_ title: String) {
        setAccessibilityLabel(String(
            format: String(
                localized: "floatingDock.parking.reorder",
                defaultValue: "Reorder %@"
            ),
            locale: .current,
            title
        ))
        setAccessibilityHelp(String(
            localized: "floatingDock.parking.reorder.help",
            defaultValue: "Drag vertically, or use the Up and Down Arrow keys."
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        isDragging = true
        window?.invalidateCursorRects(for: self)
        onDrag(.began, screenPoint(for: event))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag(.changed, screenPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        window?.invalidateCursorRects(for: self)
        onDrag(.ended, screenPoint(for: event))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            onStep(-1)
        case 125:
            onStep(1)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = isDragging
            ? NSColor.labelColor
            : NSColor.secondaryLabelColor.withAlphaComponent(isHovering ? 0.95 : 0.7)
        color.setFill()
        let dotSize: CGFloat = 2.5
        let horizontalGap: CGFloat = 5
        let verticalGap: CGFloat = 5
        let totalWidth = (dotSize * 2) + horizontalGap
        let totalHeight = (dotSize * 3) + (verticalGap * 2)
        let origin = CGPoint(
            x: floor(bounds.midX - (totalWidth / 2)),
            y: floor(bounds.midY - (totalHeight / 2))
        )
        for column in 0..<2 {
            for row in 0..<3 {
                let rect = CGRect(
                    x: origin.x + CGFloat(column) * (dotSize + horizontalGap),
                    y: origin.y + CGFloat(row) * (dotSize + verticalGap),
                    width: dotSize,
                    height: dotSize
                )
                NSBezierPath(roundedRect: rect, xRadius: dotSize / 2, yRadius: dotSize / 2).fill()
            }
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}
