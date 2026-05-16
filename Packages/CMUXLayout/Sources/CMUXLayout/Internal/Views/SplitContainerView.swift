import SwiftUI
import AppKit

private var splitContainerProgrammaticSyncDepth = 0

private class ThemedSplitView: NSSplitView {
    var customDividerColor: NSColor?

    override var dividerColor: NSColor {
        customDividerColor ?? super.dividerColor
    }

    override var isOpaque: Bool { false }

    // NSSplitView's default `mouseDownCanMoveWindow` reports `true` whenever it
    // appears opaque to AppKit, and even with `isOpaque=false` AppKit can
    // promote it back to draggable when nested inside a non-titlebar window.
    // In `presentationMode == "minimal"` (no titlebar drag region), AppKit was
    // treating mouseDowns inside the LEFT pane of a horizontal split as window
    // drag intents and consuming the mouseUp before SwiftUI's tap gesture
    // could fire on tab items. Forcing `false` here keeps the entire pane
    // hosting chain non-draggable so SwiftUI gestures get every click.
    // See `NonDraggableHostingView` in SplitNodeView.swift for the rest of
    // the chain.
    override var mouseDownCanMoveWindow: Bool { false }
}

#if DEBUG
private func debugPointString(_ point: NSPoint) -> String {
    let x = Int(point.x.rounded())
    let y = Int(point.y.rounded())
    return "\(x)x\(y)"
}

private func debugRectString(_ rect: NSRect) -> String {
    let x = Int(rect.origin.x.rounded())
    let y = Int(rect.origin.y.rounded())
    let w = Int(rect.size.width.rounded())
    let h = Int(rect.size.height.rounded())
    return "\(x):\(y)+\(w)x\(h)"
}

private final class DebugSplitView: ThemedSplitView {
    var debugSplitToken: String = "none"
    private var lastLoggedEventTimestampMs: Int = -1

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard let event = NSApp.currentEvent else { return result }
        guard event.type == .leftMouseDown else { return result }
        guard event.window == window else { return result }
        let eventTimestampMs = Int((event.timestamp * 1000).rounded())
        guard eventTimestampMs != lastLoggedEventTimestampMs else { return result }
        lastLoggedEventTimestampMs = eventTimestampMs

        let dividerRect = debugDividerRect()
        let hitRect = dividerRect?.insetBy(dx: -4, dy: -4)
        let onDivider = dividerRect?.contains(point) == true
        let nearDivider = hitRect?.contains(point) == true
        let targetClass = result.map { NSStringFromClass(type(of: $0)) } ?? "nil"

        dlog(
            "divider.hitTest split=\(debugSplitToken) point=\(debugPointString(point)) target=\(targetClass) onDivider=\(onDivider ? 1 : 0) nearDivider=\(nearDivider ? 1 : 0)"
        )

        return result
    }

    private func debugDividerRect() -> NSRect? {
        guard arrangedSubviews.count >= 2 else { return nil }

        let a = arrangedSubviews[0].frame
        let b = arrangedSubviews[1].frame
        let thickness = dividerThickness

        if isVertical {
            guard a.width > 1, b.width > 1 else { return nil }
            let x = max(0, a.maxX)
            return NSRect(x: x, y: 0, width: thickness, height: bounds.height)
        }

        guard a.height > 1, b.height > 1 else { return nil }
        let y = max(0, a.maxY)
        return NSRect(x: 0, y: y, width: bounds.width, height: thickness)
    }
}
#endif

/// SwiftUI wrapper around NSSplitView for native split behavior
struct SplitContainerView<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Bindable var splitState: SplitState
    let controller: SplitViewController
    let appearance: WorkspaceLayoutConfiguration.Appearance
    let contentBuilder: (SurfaceItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    /// Callback when geometry changes. Bool indicates if change is during active divider drag.
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    /// Animation configuration
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    func makeCoordinator() -> Coordinator {
        Coordinator(
            splitState: splitState,
            minimumPaneWidth: appearance.minimumPaneWidth,
            minimumPaneHeight: appearance.minimumPaneHeight,
            onGeometryChange: onGeometryChange
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
#if DEBUG
        let splitView: ThemedSplitView = {
            let debugSplitView = DebugSplitView()
            debugSplitView.debugSplitToken = String(splitState.id.uuidString.prefix(5))
            return debugSplitView
        }()
#else
        let splitView = ThemedSplitView()
#endif
        splitView.customDividerColor = TabBarColors.nsColorSeparator(for: appearance)
        splitView.isVertical = splitState.orientation == .horizontal
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.layer?.isOpaque = false

        // Keep arranged subviews stable (always 2) to avoid transient "collapse" flashes when
        // replacing pane<->split content. We swap the hosted content within these containers.
        // The containers use `SplitArrangedContainerView` (rather than bare NSView) so they
        // override `mouseDownCanMoveWindow=false` — see `NonDraggableHostingView` in
        // SplitNodeView.swift for the regression this guards against.
        let firstContainer = SplitArrangedContainerView()
        firstContainer.wantsLayer = true
        firstContainer.layer?.backgroundColor = NSColor.clear.cgColor
        firstContainer.layer?.isOpaque = false
        firstContainer.layer?.masksToBounds = true
        let firstController = makeHostingController(for: splitState.first)
        installHostingController(firstController, into: firstContainer)
        splitView.addArrangedSubview(firstContainer)
        context.coordinator.firstHostingController = firstController

        let secondContainer = SplitArrangedContainerView()
        secondContainer.wantsLayer = true
        secondContainer.layer?.backgroundColor = NSColor.clear.cgColor
        secondContainer.layer?.isOpaque = false
        secondContainer.layer?.masksToBounds = true
        let secondController = makeHostingController(for: splitState.second)
        installHostingController(secondController, into: secondContainer)
        splitView.addArrangedSubview(secondContainer)
        context.coordinator.secondHostingController = secondController

        context.coordinator.splitView = splitView

        // Capture animation origin before it gets cleared
        let animationOrigin = splitState.animationOrigin
#if DEBUG
        let splitDebugToken = String(splitState.id.uuidString.prefix(5))
        let orientationToken = splitState.orientation == .horizontal ? "horizontal" : "vertical"
        let animationOriginToken: String = {
            guard let animationOrigin else { return "none" }
            switch animationOrigin {
            case .fromFirst: return "fromFirst"
            case .fromSecond: return "fromSecond"
            }
        }()
#endif

        // Determine which pane is new (will be hidden initially)
        let newPaneIndex = animationOrigin == .fromFirst ? 0 : 1

        // Capture animation settings for async block
        let shouldAnimate = enableAnimations && animationOrigin != nil
        let duration = animationDuration

        if animationOrigin != nil {
            // Clear immediately so we don't re-animate on updates
            splitState.animationOrigin = nil

            if shouldAnimate {
                // Hide the NEW pane immediately to prevent flash
                splitView.arrangedSubviews[newPaneIndex].isHidden = true

                // Track that we're animating (skip delegate position updates)
                context.coordinator.isAnimating = true
            }
        }

        // Apply the initial divider position once after initial layout scheduling.
        func applyInitialDividerPosition() {
            if context.coordinator.didApplyInitialDividerPosition {
                return
            }

            let totalSize = splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
            let availableSize = max(totalSize - splitView.dividerThickness, 0)

            guard availableSize > 0 else {
                // makeNSView can run before NSSplitView has a real frame; retry on the
                // next runloop so we still get the intended entry animation.
                context.coordinator.initialDividerApplyAttempts += 1
#if DEBUG
                let attempt = context.coordinator.initialDividerApplyAttempts
                if attempt == 1 || attempt == 4 || attempt == 8 || attempt == 12 {
                    dlog(
                        "split.entry.wait split=\(splitDebugToken) orientation=\(orientationToken) " +
                        "origin=\(animationOriginToken) animate=\(shouldAnimate ? 1 : 0) " +
                        "attempt=\(attempt) total=\(Int(totalSize.rounded())) available=\(Int(availableSize.rounded()))"
                    )
                }
#endif
                if context.coordinator.initialDividerApplyAttempts < 12 {
                    DispatchQueue.main.async {
                        applyInitialDividerPosition()
                    }
                    return
                }

                // Safety fallback: don't leave the new pane hidden forever.
                context.coordinator.didApplyInitialDividerPosition = true
                if animationOrigin != nil, shouldAnimate {
                    splitView.arrangedSubviews[newPaneIndex].isHidden = false
                    context.coordinator.isAnimating = false
                }
#if DEBUG
                dlog(
                    "split.entry.fallback split=\(splitDebugToken) orientation=\(orientationToken) " +
                    "origin=\(animationOriginToken) animate=\(shouldAnimate ? 1 : 0) attempts=\(context.coordinator.initialDividerApplyAttempts)"
                )
#endif
                return
            }

            context.coordinator.didApplyInitialDividerPosition = true
            context.coordinator.initialDividerApplyAttempts = 0

            if animationOrigin != nil {
                let targetPosition = availableSize * 0.5
                splitState.dividerPosition = 0.5

                if shouldAnimate {
                    // Position at edge while new pane is hidden
                    let startPosition: CGFloat = animationOrigin == .fromFirst ? 0 : availableSize
#if DEBUG
                    dlog(
                        "split.entry.start split=\(splitDebugToken) orientation=\(orientationToken) " +
                        "origin=\(animationOriginToken) newPaneIndex=\(newPaneIndex) " +
                        "startPx=\(Int(startPosition.rounded())) targetPx=\(Int(targetPosition.rounded())) " +
                        "available=\(Int(availableSize.rounded()))"
                    )
#endif
                    context.coordinator.setPositionSafely(startPosition, in: splitView, layout: true)

                    // Wait for layout
                    DispatchQueue.main.async {
                        // Show the new pane and animate
                        splitView.arrangedSubviews[newPaneIndex].isHidden = false

                        SplitAnimator.shared.animate(
                            splitView: splitView,
                            from: startPosition,
                            to: targetPosition,
                            duration: duration
                        ) {
                            context.coordinator.isAnimating = false
                            // Re-assert exact 0.5 ratio to prevent pixel-rounding drift
                            splitState.dividerPosition = 0.5
                            context.coordinator.lastAppliedPosition = 0.5
#if DEBUG
                            dlog(
                                "split.entry.complete split=\(splitDebugToken) orientation=\(orientationToken) " +
                                "origin=\(animationOriginToken) finalRatio=\(String(format: "%.3f", splitState.dividerPosition))"
                            )
#endif
                        }
                    }
                } else {
                    // No animation - just set the position immediately
                    context.coordinator.setPositionSafely(targetPosition, in: splitView, layout: false)
#if DEBUG
                    dlog(
                        "split.entry.noAnimation split=\(splitDebugToken) orientation=\(orientationToken) " +
                        "origin=\(animationOriginToken) targetPx=\(Int(targetPosition.rounded())) " +
                        "enableAnimations=\(enableAnimations ? 1 : 0)"
                    )
#endif
                }
            } else {
                // No animation - just set the position
                let position = availableSize * splitState.dividerPosition
                context.coordinator.setPositionSafely(position, in: splitView, layout: false)
            }
        }

        DispatchQueue.main.async {
            applyInitialDividerPosition()
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        // SwiftUI may reuse the same NSSplitView/Coordinator instance while the underlying SplitState
        // object changes (e.g., during split tree restructuring). Keep the coordinator pointed at
        // the latest state to avoid syncing geometry against a stale model.
        context.coordinator.update(
            splitState: splitState,
            minimumPaneWidth: appearance.minimumPaneWidth,
            minimumPaneHeight: appearance.minimumPaneHeight,
            onGeometryChange: onGeometryChange
        )

        // Hide the NSSplitView when inactive so AppKit's drag routing doesn't deliver
        // drag sessions to views belonging to background workspaces. SwiftUI's
        // .allowsHitTesting(false) only affects gesture recognizers, not AppKit's
        // view-hierarchy-based NSDraggingDestination routing.
        splitView.isHidden = !controller.isInteractive
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.layer?.isOpaque = false
        (splitView as? ThemedSplitView)?.customDividerColor = TabBarColors.nsColorSeparator(for: appearance)

        // Update orientation if changed
        splitView.isVertical = splitState.orientation == .horizontal

        // Update children. When a child's node type changes (split→pane or pane→split),
        // replace the hosted content (not the arranged subview) to ensure native NSViews
        // (e.g., Metal-backed terminals) are properly moved through the AppKit hierarchy
        // without briefly dropping arrangedSubviews to 1.
        let arranged = splitView.arrangedSubviews
        if arranged.count >= 2 {
            let firstType = splitState.first.nodeType
            let secondType = splitState.second.nodeType

            let firstContainer = arranged[0]
            let secondContainer = arranged[1]
            firstContainer.wantsLayer = true
            firstContainer.layer?.backgroundColor = NSColor.clear.cgColor
            firstContainer.layer?.isOpaque = false
            secondContainer.wantsLayer = true
            secondContainer.layer?.backgroundColor = NSColor.clear.cgColor
            secondContainer.layer?.isOpaque = false

            updateHostedContent(
                in: firstContainer,
                node: splitState.first,
                nodeTypeChanged: firstType != context.coordinator.firstNodeType,
                controller: &context.coordinator.firstHostingController
            )
            context.coordinator.firstNodeType = firstType

            updateHostedContent(
                in: secondContainer,
                node: splitState.second,
                nodeTypeChanged: secondType != context.coordinator.secondNodeType,
                controller: &context.coordinator.secondHostingController
            )
            context.coordinator.secondNodeType = secondType
        }

        // Access dividerPosition to ensure SwiftUI tracks this dependency
        // Then sync if the position changed externally
        let currentPosition = splitState.dividerPosition
        context.coordinator.syncPosition(currentPosition, in: splitView)
    }

    // MARK: - Helpers

    private func makeHostingController(for node: SplitNode) -> NonDraggableHostingController<AnyView> {
        let hostingController = NonDraggableHostingController(rootView: AnyView(makeView(for: node)))
        if #available(macOS 13.0, *) {
            // NSSplitView owns pane geometry. Keep NSHostingController from publishing
            // intrinsic-size constraints that force a minimum pane width.
            hostingController.sizingOptions = []
        }

        let hostedView = hostingController.view
        // NSSplitView lays out arranged subviews by setting frames. Leaving Auto Layout
        // enabled on these NSHostingViews can allow them to compress to 0 during
        // structural updates, collapsing panes.
        hostedView.translatesAutoresizingMaskIntoConstraints = true
        hostedView.autoresizingMask = [.width, .height]
        // Do not let SwiftUI intrinsic size push split panes wider than the model frame.
        let relaxed = NSLayoutConstraint.Priority(1)
        hostedView.setContentHuggingPriority(relaxed, for: .horizontal)
        hostedView.setContentCompressionResistancePriority(relaxed, for: .horizontal)
        hostedView.setContentHuggingPriority(relaxed, for: .vertical)
        hostedView.setContentCompressionResistancePriority(relaxed, for: .vertical)
        return hostingController
    }

    private func installHostingController(_ hostingController: NonDraggableHostingController<AnyView>, into container: NSView) {
        let hostedView = hostingController.view
        hostedView.frame = container.bounds
        hostedView.autoresizingMask = [.width, .height]
        if hostedView.superview !== container {
            container.addSubview(hostedView)
        }
    }

    private func updateHostedContent(
        in container: NSView,
        node: SplitNode,
        nodeTypeChanged: Bool,
        controller: inout NonDraggableHostingController<AnyView>?
    ) {
        // Historically we recreated the NSHostingController when the child node type changed
        // (pane <-> split) to force a full detach/reattach of native AppKit subviews.
        //
        // In practice, that can introduce a single-frame "blank flash" for Metal/IOSurface-backed
        // content during split collapse (SwiftUI tears down the old subtree before the new subtree
        // has produced its native backing views).
        //
        // Keeping the hosting controller stable and just swapping its rootView makes the update
        // atomic from AppKit's perspective and avoids the transient blank frame.
        _ = nodeTypeChanged // keep signature; behavior is intentionally identical either way.

        if let current = controller {
            current.rootView = AnyView(makeView(for: node))
            // Ensure fill if container bounds changed without a layout pass yet.
            current.view.frame = container.bounds
            return
        }

        let newController = makeHostingController(for: node)
        installHostingController(newController, into: container)
        controller = newController
    }

    @ViewBuilder
    private func makeView(for node: SplitNode) -> some View {
        switch node {
        case .pane(let paneState):
            PaneContainerView(
                pane: paneState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )
        case .split(let nestedSplitState):
            SplitContainerView(
                splitState: nestedSplitState,
                controller: controller,
                appearance: appearance,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                enableAnimations: enableAnimations,
                animationDuration: animationDuration
            )
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSSplitViewDelegate {
        var splitState: SplitState
        private var splitStateId: UUID
        private var minimumPaneWidth: CGFloat
        private var minimumPaneHeight: CGFloat
        weak var splitView: NSSplitView?
        var isAnimating = false
        var didApplyInitialDividerPosition = false
        /// Initial divider placement can run before NSSplitView has a real size.
        /// Retry a few turns so entry animations are not dropped on first layout.
        var initialDividerApplyAttempts = 0
        var onGeometryChange: ((_ isDragging: Bool) -> Void)?
        /// Track last applied position to detect external changes
        var lastAppliedPosition: CGFloat = 0.5
        // Guard programmatic `setPosition` re-entrancy from resize callbacks.
        var isSyncingProgrammatically = false
        /// Track if user is actively dragging the divider
        var isDragging = false
        /// Track child node types to detect structural changes
        var firstNodeType: SplitNode.NodeType
        var secondNodeType: SplitNode.NodeType
        /// Retain hosting controllers so SwiftUI content stays alive
        var firstHostingController: NonDraggableHostingController<AnyView>?
        var secondHostingController: NonDraggableHostingController<AnyView>?

        init(
            splitState: SplitState,
            minimumPaneWidth: CGFloat,
            minimumPaneHeight: CGFloat,
            onGeometryChange: ((_ isDragging: Bool) -> Void)?
        ) {
            self.splitState = splitState
            self.splitStateId = splitState.id
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.onGeometryChange = onGeometryChange
            self.lastAppliedPosition = splitState.dividerPosition
            self.firstNodeType = splitState.first.nodeType
            self.secondNodeType = splitState.second.nodeType
        }

        func update(
            splitState newState: SplitState,
            minimumPaneWidth: CGFloat,
            minimumPaneHeight: CGFloat,
            onGeometryChange: ((_ isDragging: Bool) -> Void)?
        ) {
            self.onGeometryChange = onGeometryChange
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight

            // If SwiftUI reused this representable for a different split node,
            // reset our cached sync state so we don't "pin" the divider to an edge.
            if newState.id != splitStateId {
                splitStateId = newState.id
                splitState = newState
                lastAppliedPosition = newState.dividerPosition
                didApplyInitialDividerPosition = false
                initialDividerApplyAttempts = 0
                isAnimating = false
                isDragging = false
                firstNodeType = newState.first.nodeType
                secondNodeType = newState.second.nodeType
                return
            }

            // Same split node; keep reference updated anyway.
            splitState = newState
        }

        private func splitTotalSize(in splitView: NSSplitView) -> CGFloat {
            splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
        }

        private func splitAvailableSize(in splitView: NSSplitView) -> CGFloat {
            max(splitTotalSize(in: splitView) - splitView.dividerThickness, 0)
        }

        private func requestedMinimumPaneSize() -> CGFloat {
            max(
                splitState.orientation == .horizontal ? minimumPaneWidth : minimumPaneHeight,
                1
            )
        }

        private func effectiveMinimumPaneSize(in splitView: NSSplitView) -> CGFloat {
            let available = splitAvailableSize(in: splitView)
            guard available > 0 else { return 0 }
            // When the container is too small for both configured minimums, keep both panes
            // visible by evenly splitting the available space rather than forcing invalid bounds.
            return min(requestedMinimumPaneSize(), available / 2)
        }

        private func normalizedDividerBounds(in splitView: NSSplitView) -> ClosedRange<CGFloat> {
            let available = splitAvailableSize(in: splitView)
            guard available > 0 else { return 0...1 }
            let minNormalized = min(0.5, effectiveMinimumPaneSize(in: splitView) / available)
            return minNormalized...(1 - minNormalized)
        }

        private func clampedDividerPosition(_ position: CGFloat, in splitView: NSSplitView) -> CGFloat {
            let available = splitAvailableSize(in: splitView)
            guard available > 0 else { return 0 }
            let minPaneSize = effectiveMinimumPaneSize(in: splitView)
            let maxPosition = max(minPaneSize, available - minPaneSize)
            return min(max(position, minPaneSize), maxPosition)
        }

        private func dividerHitRectContains(_ point: NSPoint, rect: NSRect) -> Bool {
            point.x >= rect.minX &&
                point.x <= rect.maxX &&
                point.y >= rect.minY &&
                point.y <= rect.maxY
        }
#if DEBUG
        private func debugLogDividerDragSkip(
            _ reason: String,
            splitView: NSSplitView,
            event: NSEvent? = nil,
            location: NSPoint? = nil,
            dividerRect: NSRect? = nil,
            hitRect: NSRect? = nil
        ) {
            var message = "divider.dragCheck.skip split=\(splitState.id.uuidString.prefix(5)) reason=\(reason)"
            if let event {
                let ageMs = Int(((ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000).rounded())
                message += " eventType=\(event.type.rawValue) ageMs=\(ageMs)"
            } else {
                message += " event=nil"
            }
            message += " splitWin=\(splitView.window?.windowNumber ?? -1)"
            if let location {
                message += " loc=\(debugPointString(location))"
            }
            if let dividerRect {
                message += " divider=\(debugRectString(dividerRect))"
            }
            if let hitRect {
                message += " hit=\(debugRectString(hitRect))"
            }
            dlog(message)
        }
#endif
        /// Apply external position changes to the NSSplitView
        func setPositionSafely(_ position: CGFloat, in splitView: NSSplitView, layout: Bool = true) {
            isSyncingProgrammatically = true
            splitContainerProgrammaticSyncDepth += 1
            defer {
                isSyncingProgrammatically = false
                splitContainerProgrammaticSyncDepth = max(0, splitContainerProgrammaticSyncDepth - 1)
            }
            let clampedPosition = clampedDividerPosition(position, in: splitView)
            splitView.setPosition(clampedPosition, ofDividerAt: 0)
            if layout {
                splitView.layoutSubtreeIfNeeded()
            }
        }

        func syncPosition(_ statePosition: CGFloat, in splitView: NSSplitView) {
            guard !isAnimating else { return }
            guard !isSyncingProgrammatically else { return }
            guard splitContainerProgrammaticSyncDepth == 0 else { return }

            guard splitView.arrangedSubviews.count >= 2 else {
                // Structural updates can temporarily remove an arranged subview.
                // A subsequent update/layout pass will re-apply the model position.
#if DEBUG
                WorkspaceLayoutDebugCounters.recordArrangedSubviewUnderflow()
#endif
                return
            }

            let availableSize = splitAvailableSize(in: splitView)

            // During view reparenting, NSSplitView can briefly report 0-sized bounds.
            // A later layout pass with real bounds will apply the model ratio.
            guard availableSize > 0 else { return }
            let stateBounds = normalizedDividerBounds(in: splitView)
            let clampedStatePosition = max(
                stateBounds.lowerBound,
                min(stateBounds.upperBound, statePosition)
            )

            // Keep the view in sync even if the model hasn't changed. Structural updates (pane↔split)
            // can temporarily reset divider positions; lastAppliedPosition alone isn't enough.
            let currentDividerPixels: CGFloat = {
                let firstSubview = splitView.arrangedSubviews[0]
                return splitState.orientation == .horizontal ? firstSubview.frame.width : firstSubview.frame.height
            }()
            let currentNormalized = max(
                stateBounds.lowerBound,
                min(stateBounds.upperBound, currentDividerPixels / availableSize)
            )

            if abs(clampedStatePosition - lastAppliedPosition) <= 0.01 &&
                abs(currentNormalized - clampedStatePosition) <= 0.01 {
                return
            }

            let pixelPosition = availableSize * clampedStatePosition
            setPositionSafely(pixelPosition, in: splitView, layout: true)
            lastAppliedPosition = clampedStatePosition
        }

        func splitViewWillResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            // If the left mouse button isn't down, this can't be an interactive divider drag.
            // (`splitViewWillResizeSubviews` can fire for programmatic/layout-driven resizes too.)
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
#if DEBUG
                if let event = NSApp.currentEvent,
                   event.type == .leftMouseDown || event.type == .leftMouseDragged {
                    debugLogDividerDragSkip("leftMouseNotPressed", splitView: splitView, event: event)
                }
#endif
                isDragging = false
                return
            }

            // If we're already tracking an active drag, keep the flag until mouse-up.
            if isDragging {
                return
            }

            guard let event = NSApp.currentEvent else {
#if DEBUG
                debugLogDividerDragSkip("noCurrentEvent", splitView: splitView, event: nil)
#endif
                return
            }

            // Only treat this as a divider drag if the pointer is actually on the divider.
            // This delegate callback can also fire during window resizes or structural updates,
            // and persisting divider ratios in those cases can permanently collapse a pane.
            let now = ProcessInfo.processInfo.systemUptime
            // `NSApp.currentEvent` can be stale when called from async UI work (e.g. socket commands).
            // Only trust very recent events.
            guard (now - event.timestamp) < 0.1 else {
#if DEBUG
                debugLogDividerDragSkip("staleCurrentEvent", splitView: splitView, event: event)
#endif
                return
            }
            guard event.type == .leftMouseDown || event.type == .leftMouseDragged else {
#if DEBUG
                debugLogDividerDragSkip("wrongEventType", splitView: splitView, event: event)
#endif
                return
            }
            guard event.window == splitView.window else {
#if DEBUG
                debugLogDividerDragSkip("windowMismatch", splitView: splitView, event: event)
#endif
                return
            }
            guard splitView.arrangedSubviews.count >= 2 else {
#if DEBUG
                debugLogDividerDragSkip("arrangedUnderflow", splitView: splitView, event: event)
#endif
                return
            }

            let location = splitView.convert(event.locationInWindow, from: nil)
            let a = splitView.arrangedSubviews[0].frame
            let b = splitView.arrangedSubviews[1].frame
            let thickness = splitView.dividerThickness
            let dividerRect: NSRect
            if splitView.isVertical {
                // If we don't have real frames yet (during structural updates), don't infer dragging.
                guard a.width > 1, b.width > 1 else {
#if DEBUG
                    debugLogDividerDragSkip("invalidSubviewWidths", splitView: splitView, event: event, location: location)
#endif
                    return
                }
                // Vertical divider between left/right arranged subviews.
                let x = max(0, a.maxX)
                dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
            } else {
                guard a.height > 1, b.height > 1 else {
#if DEBUG
                    debugLogDividerDragSkip("invalidSubviewHeights", splitView: splitView, event: event, location: location)
#endif
                    return
                }
                // Horizontal divider between top/bottom arranged subviews.
                let y = max(0, a.maxY)
                dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
            }
            // Match the divider's expanded effective rect and treat the max edge
            // as inside so drag tracking doesn't miss when AppKit reports a point
            // exactly on the divider boundary during multi-split resizes.
            let hitRect = dividerRect.insetBy(dx: -5, dy: -5)
            if dividerHitRectContains(location, rect: hitRect) {
                isDragging = true
#if DEBUG
                dlog(
                    "divider.dragStart split=\(splitState.id.uuidString.prefix(5)) loc=\(debugPointString(location)) divider=\(debugRectString(dividerRect)) hit=\(debugRectString(hitRect))"
                )
#endif
            } else {
#if DEBUG
                debugLogDividerDragSkip(
                    "hitRectMiss",
                    splitView: splitView,
                    event: event,
                    location: location,
                    dividerRect: dividerRect,
                    hitRect: hitRect
                )
#endif
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Skip position updates during animation
            guard !isAnimating else { return }
            guard let splitView = notification.object as? NSSplitView else { return }
#if DEBUG
            let subframes = splitView.arrangedSubviews.enumerated().map { (i, v) in
                "\(i)=\(Int(v.frame.width))x\(Int(v.frame.height))"
            }.joined(separator: " ")
            dlog("split.didResize split=\(splitState.id.uuidString.prefix(5)) orient=\(splitState.orientation == .horizontal ? "H" : "V") container=\(Int(splitView.frame.width))x\(Int(splitView.frame.height)) subs=[\(subframes)] anim=\(isAnimating ? 1 : 0) sync=\(isSyncingProgrammatically ? 1 : 0)")
#endif
            if isSyncingProgrammatically || splitContainerProgrammaticSyncDepth > 0 {
                return
            }
            // Prevent stale drag state from persisting through programmatic/async resizes.
            let leftDown = (NSEvent.pressedMouseButtons & 1) != 0
            if !leftDown {
#if DEBUG
                if isDragging {
                    dlog("divider.dragStateReset split=\(splitState.id.uuidString.prefix(5)) reason=leftMouseReleased")
                }
#endif
                isDragging = false
            }
            // During structural updates (pane↔split), arranged subviews can be temporarily removed.
            // Avoid persisting a dividerPosition derived from a transient 1-subview layout.
            guard splitView.arrangedSubviews.count >= 2 else {
#if DEBUG
                WorkspaceLayoutDebugCounters.recordArrangedSubviewUnderflow()
#endif
                return
            }

            let availableSize = splitAvailableSize(in: splitView)

            guard availableSize > 0 else { return }

            if let firstSubview = splitView.arrangedSubviews.first {
                let dividerPosition = splitState.orientation == .horizontal
                    ? firstSubview.frame.width
                    : firstSubview.frame.height

                var normalizedPosition = dividerPosition / availableSize

                // Never persist a fully-collapsed pane ratio. (This can happen if we ever
                // see a transient 0-sized layout during a drag or structural update.)
                let normalizedBounds = normalizedDividerBounds(in: splitView)
                normalizedPosition = max(
                    normalizedBounds.lowerBound,
                    min(normalizedBounds.upperBound, normalizedPosition)
                )

                // Snap to 0.5 if very close (prevents pixel-rounding drift)
                if abs(normalizedPosition - 0.5) < 0.01 {
                    normalizedPosition = 0.5
                }

                // Check if drag ended (mouse up)
                let wasDragging = isDragging && leftDown
                if let event = NSApp.currentEvent, event.type == .leftMouseUp {
#if DEBUG
                    dlog("divider.dragEnd split=\(splitState.id.uuidString.prefix(5))")
#endif
                    isDragging = false
                }

                // Only update the model when the user is actively dragging. For other resizes
                // (window resizes, view reparenting, pane↔split structural updates), the model's
                // dividerPosition should remain stable; syncPosition() will keep the view aligned.
                guard wasDragging else {
#if DEBUG
                    let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "none"
                    dlog(
                        "divider.resizeIgnored split=\(splitState.id.uuidString.prefix(5)) eventType=\(eventType) leftDown=\(leftDown ? 1 : 0) isDragging=\(isDragging ? 1 : 0) normalized=\(String(format: "%.3f", normalizedPosition)) model=\(String(format: "%.3f", self.splitState.dividerPosition))"
                    )
#endif
                    let statePosition = self.splitState.dividerPosition
                    // Re-assert synchronously. setPositionSafely sets isSyncingProgrammatically=true,
                    // so the recursive splitViewDidResizeSubviews call is caught by the guard above.
                    // Deferring to the next runloop turn would allow the transient frame to propagate
                    // through SwiftUI layout → ghostty terminal resize → reflow, causing content shifts.
                    self.syncPosition(statePosition, in: splitView)
                    self.onGeometryChange?(false)
                    return
                }

                // NSSplitView delegate callbacks already arrive on the main thread.
                // Deferring this write through a Task can replay stale divider ratios
                // via updateNSView() and make fast drags snap back to older positions.
#if DEBUG
                dlog(
                    "divider.dragUpdate split=\(splitState.id.uuidString.prefix(5)) normalized=\(String(format: "%.3f", normalizedPosition)) px=\(Int(dividerPosition.rounded())) available=\(Int(availableSize.rounded()))"
                )
#endif
                self.splitState.dividerPosition = normalizedPosition
                self.lastAppliedPosition = normalizedPosition
                // Notify geometry change with drag state
                self.onGeometryChange?(wasDragging)
            }
        }

        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            let expanded = drawnRect.insetBy(dx: -5, dy: -5)
            return proposedEffectiveRect.union(expanded)
        }

        func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
            guard splitView.arrangedSubviews.count >= dividerIndex + 2 else { return .zero }

            let first = splitView.arrangedSubviews[dividerIndex].frame
            let second = splitView.arrangedSubviews[dividerIndex + 1].frame
            let thickness = splitView.dividerThickness

            let dividerRect: NSRect
            if splitView.isVertical {
                guard first.width > 1, second.width > 1 else { return .zero }
                let x = max(0, first.maxX)
                dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
            } else {
                guard first.height > 1, second.height > 1 else { return .zero }
                let y = max(0, first.maxY)
                dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
            }

            return dividerRect.insetBy(dx: -5, dy: -5)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            // Allow edge positions during animation
            guard !isAnimating else { return proposedMinimumPosition }
            return max(proposedMinimumPosition, effectiveMinimumPaneSize(in: splitView))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            // Allow edge positions during animation
            guard !isAnimating else { return proposedMaximumPosition }
            let availableSize = splitAvailableSize(in: splitView)
            let minimumPaneSize = effectiveMinimumPaneSize(in: splitView)
            let maxCoordinate = max(minimumPaneSize, availableSize - minimumPaneSize)
            return min(proposedMaximumPosition, maxCoordinate)
        }
    }
}
