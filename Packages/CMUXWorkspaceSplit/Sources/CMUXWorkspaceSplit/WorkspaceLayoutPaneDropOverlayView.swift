import AppKit
import UniformTypeIdentifiers

final class WorkspaceLayoutPaneDropOverlayView: NSView {
    var paneId: PaneID?
    var hostBridge: (WorkspaceLayoutInteractionHandlers)?
    var presentation: WorkspaceLayoutPresentationSnapshot?
    var localTabDrag: WorkspaceLayoutLocalDragSnapshot?
    var onZoneUpdated: ((DropZone) -> Void)?
    var onZoneCleared: (() -> Void)?
    var onDropSucceeded: (() -> Void)?
    var onHideAnimationCompleted: ((UInt64) -> Void)?
    var onDropPerformed: (() -> Void)?
    let overlayShapeView = NSView(frame: .zero)
    var overlayPresentation: WorkspacePaneDropOverlayPresentation = .hidden

    var hitTestPassthroughEnabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        overlayShapeView.wantsLayer = true
        overlayShapeView.isHidden = true
        overlayShapeView.alphaValue = 1
        if let layer = overlayShapeView.layer {
            layer.cornerRadius = 8
            layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.borderWidth = 2
        }
        addSubview(overlayShapeView)
        registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.tabTransfer.identifier),
            .fileURL,
            .URL
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestPassthroughEnabled ? nil : super.hitTest(point)
    }

    override func layout() {
        super.layout()
        guard let zone = overlayPresentation.zone else { return }
        let targetFrame = WorkspacePaneDropRouting.overlayFrame(for: zone, in: bounds.size)
        if !Self.rectApproximatelyEqual(overlayShapeView.frame, targetFrame) {
            overlayShapeView.frame = targetFrame
        }
    }

    func update(
        paneId: PaneID,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        presentation: WorkspaceLayoutPresentationSnapshot,
        localTabDrag: WorkspaceLayoutLocalDragSnapshot?,
        overlayPresentation: WorkspacePaneDropOverlayPresentation,
        onZoneUpdated: @escaping (DropZone) -> Void,
        onZoneCleared: @escaping () -> Void,
        onDropSucceeded: @escaping () -> Void,
        onHideAnimationCompleted: @escaping (UInt64) -> Void,
        onDropPerformed: @escaping () -> Void
    ) {
        self.paneId = paneId
        self.hostBridge = hostBridge
        self.presentation = presentation
        self.localTabDrag = localTabDrag
        self.onZoneUpdated = onZoneUpdated
        self.onZoneCleared = onZoneCleared
        self.onDropSucceeded = onDropSucceeded
        self.onHideAnimationCompleted = onHideAnimationCompleted
        self.onDropPerformed = onDropPerformed
        updateOverlayPresentation(overlayPresentation)
    }

    func updateLocalTabDrag(_ localTabDrag: WorkspaceLayoutLocalDragSnapshot?) {
        self.localTabDrag = localTabDrag
    }

    func updateOverlayPresentation(_ overlayPresentation: WorkspacePaneDropOverlayPresentation) {
        let previousPresentation = self.overlayPresentation
        guard previousPresentation != overlayPresentation else { return }
        self.overlayPresentation = overlayPresentation
        applyOverlayPresentationTransition(from: previousPresentation, to: overlayPresentation)
    }

    static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    func applyOverlayPresentationTransition(
        from previousPresentation: WorkspacePaneDropOverlayPresentation,
        to nextPresentation: WorkspacePaneDropOverlayPresentation
    ) {
        switch nextPresentation.phase {
        case .hidden:
            overlayShapeView.layer?.removeAllAnimations()
            overlayShapeView.isHidden = true
            overlayShapeView.alphaValue = 1

        case .visible:
            guard let zone = nextPresentation.zone else { return }
            let targetFrame = WorkspacePaneDropRouting.overlayFrame(for: zone, in: bounds.size)
            let isSameFrame = Self.rectApproximatelyEqual(overlayShapeView.frame, targetFrame)
            let zoneChanged = previousPresentation.zone != zone

            if overlayShapeView.isHidden || previousPresentation.phase != .visible {
                overlayShapeView.layer?.removeAllAnimations()
                overlayShapeView.frame = targetFrame
                overlayShapeView.alphaValue = 0
                overlayShapeView.isHidden = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    overlayShapeView.animator().alphaValue = 1
                }
                return
            }

            if zoneChanged && !isSameFrame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    overlayShapeView.animator().frame = targetFrame
                }
            } else if !isSameFrame {
                overlayShapeView.frame = targetFrame
            }

            if overlayShapeView.alphaValue < 1 {
                overlayShapeView.layer?.removeAllAnimations()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    overlayShapeView.animator().alphaValue = 1
                }
            }

        case .hiding:
            guard let zone = nextPresentation.zone else {
                onHideAnimationCompleted?(nextPresentation.generation)
                return
            }

            let targetFrame = WorkspacePaneDropRouting.overlayFrame(for: zone, in: bounds.size)
            if !Self.rectApproximatelyEqual(overlayShapeView.frame, targetFrame) {
                overlayShapeView.frame = targetFrame
            }
            overlayShapeView.layer?.removeAllAnimations()
            guard !overlayShapeView.isHidden else {
                onHideAnimationCompleted?(nextPresentation.generation)
                return
            }

            let generation = nextPresentation.generation
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlayShapeView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.overlayPresentation.phase == .hiding else { return }
                    guard self.overlayPresentation.generation == generation else { return }
                    self.overlayShapeView.isHidden = true
                    self.overlayShapeView.alphaValue = 1
                    self.onHideAnimationCompleted?(generation)
                }
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let paneId, let presentation else { return [] }
        guard presentation.isInteractive else { return [] }

        if sender.draggingPasteboard.availableType(from: [NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)]) != nil {
            guard localTabDrag != nil
                || workspaceSplitDecodeTransfer(from: sender.draggingPasteboard)?.isFromCurrentProcess == true else {
                return []
            }
            let location = convert(sender.draggingLocation, from: nil)
            let sourcePaneId = localTabDrag?.sourcePaneId
            let decision = WorkspacePaneDropRouting.decision(
                for: location,
                in: bounds.size,
                targetPaneId: paneId,
                sourcePaneId: sourcePaneId
            )
            let zone = decision.finalZone
            onZoneUpdated?(zone)
            return .move
        }

        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        if let urls, !urls.isEmpty {
            onZoneUpdated?(.center)
            return .copy
        }

        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onZoneCleared?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let paneId, let hostBridge else { return false }

        if sender.draggingPasteboard.availableType(from: [NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)]) != nil {
            let zone = overlayPresentation.zone ?? WorkspacePaneDropRouting.zone(
                for: convert(sender.draggingLocation, from: nil),
                in: bounds.size
            )

            if let localDrag = localTabDrag {
                let draggedTabId = localDrag.tabId
                let sourcePaneId = localDrag.sourcePaneId
                hostBridge.clearDragState()

                if zone == .center {
                    if sourcePaneId != paneId {
                        _ = hostBridge.moveTab(draggedTabId, toPane: paneId, atIndex: nil)
                    }
                    onDropSucceeded?()
                    onDropPerformed?()
                    return true
                }

                guard let orientation = zone.orientation else {
                    onZoneCleared?()
                    return false
                }
                _ = hostBridge.splitPane(
                    paneId,
                    orientation: orientation,
                    movingTab: draggedTabId,
                    insertFirst: zone.insertsFirst,
                    focusNewPane: true
                )
                onDropSucceeded?()
                onDropPerformed?()
                return true
            }

            guard let transfer = workspaceSplitDecodeTransfer(from: sender.draggingPasteboard),
                  transfer.isFromCurrentProcess else {
                onZoneCleared?()
                return false
            }

            let destination: WorkspaceLayoutExternalTabDropRequest.Destination
            if zone == .center {
                destination = .insert(targetPane: paneId, targetIndex: nil)
            } else if let orientation = zone.orientation {
                destination = .split(targetPane: paneId, orientation: orientation, insertFirst: zone.insertsFirst)
            } else {
                return false
            }

            let request = WorkspaceLayoutExternalTabDropRequest(
                tabId: transfer.tabId,
                sourcePaneId: PaneID(id: transfer.sourcePaneId),
                destination: destination
            )
            let handled = hostBridge.handleExternalTabDrop(request)
            if handled {
                onDropSucceeded?()
                onDropPerformed?()
            } else {
                onZoneCleared?()
            }
            return handled
        }

        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        let handled = hostBridge.handleFileDrop(urls, in: paneId)
        if handled {
            onDropSucceeded?()
            onDropPerformed?()
        } else {
            onZoneCleared?()
        }
        return handled
    }
}

func workspaceSplitSymbolImage(named name: String) -> NSImage? {
    let size = (name == "terminal.fill" || name == "terminal" || name == "globe")
        ? max(10, TabBarMetrics.iconSize - 2.5)
        : TabBarMetrics.iconSize
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
}

func workspaceSplitTemplateSymbolImage(
    named name: String,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    fitting slotSize: CGSize? = nil
) -> NSImage? {
    func image(for candidatePointSize: CGFloat) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: candidatePointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    guard let slotSize else {
        return image(for: pointSize)
    }

    var candidatePointSize = pointSize
    var lastImage: NSImage?
    while candidatePointSize >= 1 {
        guard let candidate = image(for: candidatePointSize) else { break }
        lastImage = candidate
        if candidate.size.width <= slotSize.width, candidate.size.height <= slotSize.height {
            return candidate
        }
        candidatePointSize -= 0.5
    }
    return lastImage
}

func workspaceSplitSymbolImage(
    named name: String,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
) -> NSImage? {
    let pointConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [color])
    let configuration = pointConfiguration.applying(colorConfiguration)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
}

func workspaceSplitDrawSymbol(
    named name: String,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    in slotRect: CGRect
) {
    guard let image = workspaceSplitSymbolImage(
        named: name,
        pointSize: pointSize,
        weight: weight,
        color: color
    ) else {
        return
    }
    let fittedSize: CGSize
    if image.size.width > slotRect.width || image.size.height > slotRect.height {
        let scale = min(slotRect.width / image.size.width, slotRect.height / image.size.height)
        fittedSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    } else {
        fittedSize = image.size
    }
    let fittedScale = image.size.width > 0 ? fittedSize.width / image.size.width : 1
    let opticalCenterOffset = name == "xmark"
        ? workspaceLayoutVisibleAlphaCenterOffset(for: image).applying(
            CGAffineTransform(scaleX: fittedScale, y: fittedScale)
        )
        : .zero
    let drawRect = CGRect(
        x: slotRect.midX - (fittedSize.width / 2) + opticalCenterOffset.x,
        y: slotRect.midY - (fittedSize.height / 2) + opticalCenterOffset.y,
        width: fittedSize.width,
        height: fittedSize.height
    )
    image.draw(
        in: drawRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
}

func workspaceLayoutVisibleAlphaCenterOffset(
    for image: NSImage,
    alphaThreshold: UInt8 = 8
) -> CGPoint {
    guard let buffer = workspaceLayoutRGBAImageBuffer(from: image) else { return .zero }
    var minX = buffer.width
    var minY = buffer.height
    var maxX = -1
    var maxY = -1

    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            let base = ((y * buffer.width) + x) * 4
            if buffer.bytes[base + 3] <= alphaThreshold {
                continue
            }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { return .zero }

    let imageCenterX = CGFloat(buffer.width) / 2
    let imageCenterY = CGFloat(buffer.height) / 2
    let visibleCenterX = CGFloat(minX + maxX + 1) / 2
    let visibleCenterY = CGFloat(minY + maxY + 1) / 2
    let pointScaleX = image.size.width / CGFloat(buffer.width)
    let pointScaleY = image.size.height / CGFloat(buffer.height)

    return CGPoint(
        x: (imageCenterX - visibleCenterX) * pointScaleX,
        y: (imageCenterY - visibleCenterY) * pointScaleY
    )
}

func workspaceSplitAddMenuItem(
    _ title: String,
    action: TabContextAction,
    to menu: NSMenu,
    enabled: Bool = true,
    handler: ((TabContextAction) -> Void)?
) {
    let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.invoke(_:)), keyEquivalent: "")
    let target = ClosureMenuTarget {
        handler?(action)
    }
    item.target = target
    item.isEnabled = enabled
    objc_setAssociatedObject(item, Unmanaged.passUnretained(item).toOpaque(), target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    menu.addItem(item)
}
