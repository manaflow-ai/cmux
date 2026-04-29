import AppKit

final class WorkspaceLayoutNativeSplitView: NSSplitView, NSSplitViewDelegate {
    let hostBridge: WorkspaceLayoutInteractionHandlers
    weak var rootHost: WorkspaceLayoutRootHostView?
    var splitId: UUID
    var splitOrientation: SplitOrientation
    var splitDividerPosition: CGFloat
    var splitAnimationOrigin: SplitAnimationOrigin?
    var splitAppearance: WorkspaceLayoutConfiguration.Appearance

    let firstContainer = NSView(frame: .zero)
    let secondContainer = NSView(frame: .zero)
    weak var firstChild: NSView?
    weak var secondChild: NSView?

    var lastAppliedPosition: CGFloat
    var isSyncingProgrammatically = false
    var didApplyInitialDividerPosition = false
    var initialDividerApplyAttempts = 0
    var isAnimatingEntry = false

    init(
        snapshot: WorkspaceLayoutSplitRenderSnapshot,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        rootHost: WorkspaceLayoutRootHostView,
        firstChild: NSView,
        secondChild: NSView,
        appearance: WorkspaceLayoutConfiguration.Appearance
    ) {
        self.hostBridge = hostBridge
        self.rootHost = rootHost
        self.splitId = snapshot.splitId
        self.splitOrientation = snapshot.orientation
        self.splitDividerPosition = snapshot.dividerPosition
        self.splitAnimationOrigin = snapshot.animationOrigin
        self.splitAppearance = appearance
        self.lastAppliedPosition = snapshot.dividerPosition
        super.init(frame: .zero)
        delegate = self
        dividerStyle = .thin
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isVertical = snapshot.orientation == .horizontal
        addArrangedSubview(firstContainer)
        addArrangedSubview(secondContainer)
        configure(container: firstContainer)
        configure(container: secondContainer)
        install(child: firstChild, in: firstContainer, current: &self.firstChild)
        install(child: secondChild, in: secondContainer, current: &self.secondChild)
        updateDividerColor()
        applyInitialDividerPositionIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        snapshot: WorkspaceLayoutSplitRenderSnapshot,
        hostBridge: WorkspaceLayoutInteractionHandlers,
        rootHost: WorkspaceLayoutRootHostView,
        firstChild: NSView,
        secondChild: NSView,
        appearance: WorkspaceLayoutConfiguration.Appearance
    ) {
        if self.splitId != snapshot.splitId {
            didApplyInitialDividerPosition = false
            initialDividerApplyAttempts = 0
            isAnimatingEntry = false
        }

        self.rootHost = rootHost
        self.splitId = snapshot.splitId
        self.splitOrientation = snapshot.orientation
        self.splitDividerPosition = snapshot.dividerPosition
        self.splitAnimationOrigin = snapshot.animationOrigin
        self.splitAppearance = appearance
        isHidden = rootHost.isHidden
        isVertical = snapshot.orientation == .horizontal
        updateDividerColor()
        guard rootHost.isCurrentSplitHost(self, for: snapshot.splitId) else { return }
        install(child: firstChild, in: firstContainer, current: &self.firstChild)
        install(child: secondChild, in: secondContainer, current: &self.secondChild)
        syncDividerPosition()
    }

    func removeAllChildren() {
        workspaceLayoutRemoveSubviewIfOwned(firstChild, from: firstContainer)
        workspaceLayoutRemoveSubviewIfOwned(secondChild, from: secondContainer)
        firstChild = nil
        secondChild = nil
    }

    override func layout() {
        super.layout()
        firstContainer.frame = arrangedSubviews.first?.frame ?? .zero
        secondContainer.frame = arrangedSubviews.dropFirst().first?.frame ?? .zero
        applyInitialDividerPositionIfNeeded()
    }

    func configure(container: NSView) {
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.masksToBounds = true
    }

    func install(child: NSView, in container: NSView, current: inout NSView?) {
        if current !== child {
            workspaceLayoutRemoveSubviewIfOwned(current, from: container)
            if child.superview !== container {
                child.removeFromSuperview()
                container.addSubview(child)
            }
            current = child
        } else if child.superview !== container {
            child.removeFromSuperview()
            container.addSubview(child)
        }
        child.frame = container.bounds
        child.autoresizingMask = [.width, .height]
    }

    func updateDividerColor() {
        if let layer {
            layer.backgroundColor = NSColor.clear.cgColor
        }
        needsDisplay = true
    }

    override var dividerColor: NSColor {
        TabBarColors.nsColorSeparator(for: splitAppearance)
    }

    func applyInitialDividerPositionIfNeeded() {
        guard !didApplyInitialDividerPosition else { return }

        let available = availableSplitSize
        guard available > 0 else {
            initialDividerApplyAttempts += 1
            guard initialDividerApplyAttempts < 8 else {
                didApplyInitialDividerPosition = true
                consumePendingAnimationOriginIfNeeded()
                return
            }
            Task { @MainActor [weak self] in
                self?.applyInitialDividerPositionIfNeeded()
            }
            return
        }

        didApplyInitialDividerPosition = true
        let targetPosition = round(available * splitDividerPosition)

        guard splitAppearance.enableAnimations,
              let animationOrigin = splitAnimationOrigin else {
            consumePendingAnimationOriginIfNeeded()
            setDividerPosition(targetPosition, layout: false)
            return
        }

        let startPosition: CGFloat = animationOrigin == .fromFirst ? 0 : available
        consumePendingAnimationOriginIfNeeded()
        isAnimatingEntry = true
        setDividerPosition(startPosition, layout: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            SplitAnimator.shared.animate(
                splitView: self,
                from: startPosition,
                to: targetPosition,
                duration: self.splitAppearance.animationDuration
            ) { [weak self] in
                guard let self else { return }
                self.isAnimatingEntry = false
                self.lastAppliedPosition = self.splitDividerPosition
                self.rootHost?.notifyGeometryChanged(isDragging: false)
            }
        }
    }

    var availableSplitSize: CGFloat {
        let total = isVertical ? bounds.width : bounds.height
        return max(0, total - dividerThickness)
    }

    func setDividerPosition(_ position: CGFloat, layout: Bool) {
        guard arrangedSubviews.count >= 2 else { return }
        isSyncingProgrammatically = true
        setPosition(position, ofDividerAt: 0)
        if layout {
            layoutSubtreeIfNeeded()
        }
        isSyncingProgrammatically = false
        lastAppliedPosition = availableSplitSize > 0 ? position / availableSplitSize : splitDividerPosition
    }

    func syncDividerPosition() {
        guard !isAnimatingEntry else { return }
        let available = availableSplitSize
        guard available > 0 else { return }
        let desired = min(max(splitDividerPosition, 0.1), 0.9)
        guard abs(desired - lastAppliedPosition) > 0.0005 else { return }
        setDividerPosition(round(available * desired), layout: false)
    }

    func normalizedDividerPosition() -> CGFloat {
        guard arrangedSubviews.count >= 2 else { return splitDividerPosition }
        let firstFrame = arrangedSubviews[0].frame
        let available = availableSplitSize
        guard available > 0 else { return splitDividerPosition }
        let occupied = isVertical ? firstFrame.width : firstFrame.height
        return min(max(occupied / available, 0.1), 0.9)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isSyncingProgrammatically else { return }
        let next = normalizedDividerPosition()
        splitDividerPosition = next
        _ = hostBridge.setDividerPosition(next, forSplit: splitId)
        lastAppliedPosition = next
        let eventType = NSApp.currentEvent?.type
        let isDragging = eventType == .leftMouseDragged
        rootHost?.notifyGeometryChanged(isDragging: isDragging)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let minimum = isVertical ? splitAppearance.minimumPaneWidth : splitAppearance.minimumPaneHeight
        return minimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let minimum = isVertical ? splitAppearance.minimumPaneWidth : splitAppearance.minimumPaneHeight
        let total = isVertical ? splitView.bounds.width : splitView.bounds.height
        return max(minimum, total - minimum - splitView.dividerThickness)
    }

    func consumePendingAnimationOriginIfNeeded() {
        guard splitAnimationOrigin != nil else { return }
        splitAnimationOrigin = nil
        hostBridge.consumeSplitEntryAnimation(splitId)
    }
}
