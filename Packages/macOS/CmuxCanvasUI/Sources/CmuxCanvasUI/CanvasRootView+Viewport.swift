public import AppKit
import QuartzCore
import CmuxCanvas


extension CanvasRootView: CanvasViewportControlling {
    private static let discreteZoomAnimationKey = "cmux.canvas.discreteZoom"
    private static let discreteZoomAnimationDuration: TimeInterval = 0.2

    public func modelDidChangeExternally(animated: Bool) {
        reconcilePanes()
        applyZOrder()
        recomputeDocumentGeometry()
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                for (paneID, paneView) in paneViews {
                    if let frame = model.layout.frame(of: paneID)?.cgRect {
                        paneView.animator().frame = documentRect(fromCanvas: frame)
                    }
                }
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.callbacks.onViewportGeometryChanged(self.window)
                }
            })
        } else {
            applyAllPaneFrames()
        }
        updateLifecycle()
        updateMinimap()
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    public func revealPane(_ panelId: UUID, animated: Bool) {
        cancelDiscreteZoomAnimation()
        guard let frame = model.frame(of: panelId) else { return }
        let docFrame = documentRect(fromCanvas: frame)
        let visible = scrollView.contentView.documentVisibleRect
        let origin = CanvasViewportMath().originToReveal(
            CanvasRect(docFrame),
            viewportOrigin: CanvasPoint(visible.origin),
            viewportSize: CanvasSize(visible.size),
            margin: Self.revealMargin
        )
        guard origin.cgPoint != visible.origin else { return }
        setClipOrigin(origin.cgPoint, animated: animated)
    }

    public func zoom(by factor: CGFloat) {
        // An explicit zoom invalidates the overview round-trip restore.
        overviewRestore = nil
        let target = min(
            max(scrollView.magnification * factor, scrollView.minMagnification),
            scrollView.maxMagnification
        )
        setMagnification(target)
    }

    public func resetZoom() {
        overviewRestore = nil
        setMagnification(1.0)
    }

    public var currentMagnification: CGFloat {
        scrollView.magnification
    }

    public var currentCenterInCanvas: CGPoint {
        let visible = scrollView.contentView.documentVisibleRect
        let canvas = canvasRect(fromDocument: visible)
        return CGPoint(x: canvas.midX, y: canvas.midY)
    }

    public func setViewport(center: CGPoint, magnification: CGFloat?) {
        setViewport(center: center, magnification: magnification, notifySettled: true)
    }

    func setViewport(center: CGPoint, magnification: CGFloat?, notifySettled: Bool) {
        // An explicit viewport set invalidates the overview round-trip restore.
        overviewRestore = nil
        cancelDiscreteZoomAnimation()
        applyViewport(center: center, magnification: magnification, notifySettled: notifySettled)
    }

    private func applyViewport(
        center: CGPoint,
        magnification: CGFloat?,
        notifySettled: Bool,
        notifyGeometry: Bool = true
    ) {
        let targetMagnification: CGFloat
        if let magnification {
            targetMagnification = min(
                max(magnification, scrollView.minMagnification),
                scrollView.maxMagnification
            )
        } else {
            targetMagnification = scrollView.magnification
        }
        // Convert the desired canvas center to document coordinates, then place
        // the clip origin so that point lands at the viewport center.
        let docCenter = CGPoint(
            x: center.x - documentOriginInCanvas.x,
            y: center.y - documentOriginInCanvas.y
        )
        let viewportSize = scrollView.contentSize
        let clipSize = CGSize(
            width: viewportSize.width / targetMagnification,
            height: viewportSize.height / targetMagnification
        )
        let targetOrigin = CGPoint(
            x: docCenter.x - clipSize.width / 2,
            y: docCenter.y - clipSize.height / 2
        )
        scrollView.magnification = targetMagnification
        scrollView.contentView.setBoundsOrigin(targetOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateMinimap(reveal: true)
        if notifyGeometry {
            callbacks.onViewportGeometryChanged(window)
        }
        if notifySettled {
            callbacks.onViewportSettled(window)
        }
    }

    /// Zooms by `factor` while keeping the document point under
    /// `windowLocation` fixed (cursor-anchored), for pointer-driven zoom
    /// (option+scroll). Unanimated so it tracks the wheel; the caller settles
    /// portals on a debounce.
    func zoom(by factor: CGFloat, towardWindowLocation windowLocation: CGPoint) {
        overviewRestore = nil
        cancelDiscreteZoomAnimation()
        let target = min(
            max(scrollView.magnification * factor, scrollView.minMagnification),
            scrollView.maxMagnification
        )
        guard target != scrollView.magnification else { return }
        let anchor = scrollView.contentView.convert(windowLocation, from: nil)
        scrollView.setMagnification(target, centeredAt: anchor)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateMinimap(reveal: true)
    }

    /// Applies `magnification`, keeping the current viewport center fixed.
    private func setMagnification(_ magnification: CGFloat) {
        cancelDiscreteZoomAnimation()
        guard magnification != scrollView.magnification else { return }
        let center = currentCenterInCanvas
        if shouldReduceMotionForDiscreteZoom() {
            applyViewport(center: center, magnification: magnification, notifySettled: true)
            return
        }
        animateDiscreteZoom(to: magnification, centeredAtCanvas: center)
    }

    private func animateDiscreteZoom(to magnification: CGFloat, centeredAtCanvas center: CGPoint) {
        guard let layer = documentView.layer else {
            applyViewport(center: center, magnification: magnification, notifySettled: true)
            return
        }
        let sourceMagnification = scrollView.magnification
        guard sourceMagnification > 0 else {
            applyViewport(center: center, magnification: magnification, notifySettled: true)
            return
        }

        let sourceVisibleCanvas = canvasRect(fromDocument: scrollView.contentView.documentVisibleRect)
        applyViewport(center: center, magnification: magnification, notifySettled: false, notifyGeometry: false)
        recomputeDocumentGeometry()
        applyAllPaneFrames()

        let targetMagnification = scrollView.magnification
        guard targetMagnification > 0 else {
            callbacks.onViewportSettled(window)
            return
        }
        let sourceVisibleInTargetDocument = documentRect(fromCanvas: sourceVisibleCanvas)
        updateLifecycle(visibleRect: sourceVisibleInTargetDocument.union(scrollView.contentView.documentVisibleRect))
        updateMinimap(reveal: true)
        callbacks.onViewportGeometryChanged(window)

        let targetAnchor = CGPoint(
            x: center.x - documentOriginInCanvas.x,
            y: center.y - documentOriginInCanvas.y
        )
        let compensationScale = sourceMagnification / targetMagnification
        var compensation = CATransform3DIdentity
        compensation = CATransform3DTranslate(compensation, targetAnchor.x, targetAnchor.y, 0)
        compensation = CATransform3DScale(compensation, compensationScale, compensationScale, 1)
        compensation = CATransform3DTranslate(compensation, -targetAnchor.x, -targetAnchor.y, 0)

        discreteZoomAnimationGeneration &+= 1
        let generation = discreteZoomAnimationGeneration
        isDiscreteZoomAnimationActive = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.discreteZoomAnimationKey)
        layer.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: compensation)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = Self.discreteZoomAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishDiscreteZoomAnimation(generation: generation)
            }
        }
        layer.add(animation, forKey: Self.discreteZoomAnimationKey)
        CATransaction.commit()
    }

    func cancelDiscreteZoomAnimation() {
        guard isDiscreteZoomAnimationActive || documentView.layer?.animation(forKey: Self.discreteZoomAnimationKey) != nil else {
            return
        }
        isDiscreteZoomAnimationActive = false
        discreteZoomAnimationGeneration &+= 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentView.layer?.removeAnimation(forKey: Self.discreteZoomAnimationKey)
        documentView.layer?.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
    }

    func finishDiscreteZoomAnimation(generation: UInt64? = nil) {
        if let generation, generation != discreteZoomAnimationGeneration { return }
        guard isDiscreteZoomAnimationActive else { return }
        isDiscreteZoomAnimationActive = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentView.layer?.removeAnimation(forKey: Self.discreteZoomAnimationKey)
        documentView.layer?.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
        callbacks.onViewportSettled(window)
    }

    public func toggleOverview() {
        cancelDiscreteZoomAnimation()
        if let restore = overviewRestore {
            overviewRestore = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.animator().magnification = restore.magnification
                scrollView.contentView.animator().setBoundsOrigin(restore.origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            updateMinimap(reveal: true)
            return
        }
        guard let content = model.contentBounds else { return }
        overviewRestore = (scrollView.magnification, scrollView.contentView.bounds.origin)
        let viewportSize = scrollView.contentSize
        let fit = CGFloat(CanvasViewportMath().magnificationToFit(
            CanvasRect(content),
            in: CanvasSize(viewportSize),
            padding: Self.overviewPadding,
            range: Double(scrollView.minMagnification)...Double(scrollView.maxMagnification)
        ))
        // Anchor explicitly: after magnification `fit`, the clip's bounds are
        // viewport/fit in document coordinates; centering the content means
        // origin = contentCenter - clipSize/2. setMagnification(centeredAt:)
        // alone lands off-center when the magnification change is large.
        let docCenter = documentRect(fromCanvas: content).canvasCenter
        let clipSize = CGSize(width: viewportSize.width / fit, height: viewportSize.height / fit)
        let targetOrigin = CGPoint(
            x: docCenter.x - clipSize.width / 2,
            y: docCenter.y - clipSize.height / 2
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            scrollView.animator().magnification = fit
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateMinimap(reveal: true)
    }
}
