import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Hosted Inspector Divider Hit Testing & Drag
extension WebViewRepresentable.HostContainerView {
        func shouldPassThroughToSidebarResizer(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) -> Bool {
            if hostedInspectorHit != nil {
                return false
            }
            // Pass through narrow content-edge bands so shared sidebar divider
            // handles receive hover/click even when WKWebView is attached here.
            let isLeadingContentEdge = point.x >= 0 &&
                point.x <= SidebarResizeInteraction.contentSideHitWidth
            let isTrailingContentEdge = point.x >= bounds.maxX - SidebarResizeInteraction.contentSideHitWidth &&
                point.x <= bounds.maxX
            guard isLeadingContentEdge || isTrailingContentEdge else {
                return false
            }
            guard let window, let contentView = window.contentView else {
                return false
            }
            let hostRectInContent = contentView.convert(bounds, from: self)
            if isLeadingContentEdge {
                return hostRectInContent.minX > 1
            }
            return contentView.bounds.maxX - hostRectInContent.maxX > 24
        }

        func updateDividerCursor(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit? = nil
        ) {
            let resolvedHostedInspectorHit = hostedInspectorHit ?? hostedInspectorDividerHit(at: point)
            if shouldPassThroughToSidebarResizer(at: point, hostedInspectorHit: resolvedHostedInspectorHit) {
                clearActiveDividerCursor(restoreArrow: false)
                return
            }
            guard resolvedHostedInspectorHit != nil else {
                clearActiveDividerCursor(restoreArrow: true)
                return
            }
            activeDividerCursorKind = .vertical
            NSCursor.resizeLeftRight.set()
        }

        func clearActiveDividerCursor(restoreArrow: Bool) {
            guard activeDividerCursorKind != nil else { return }
            window?.invalidateCursorRects(for: self)
            activeDividerCursorKind = nil
            if restoreArrow {
                NSCursor.arrow.set()
            }
        }

        func nativeHostedInspectorHit(
            at point: NSPoint,
            hostedInspectorHit: HostedInspectorDividerHit
        ) -> NSView? {
            guard let nativeHit = super.hitTest(point), nativeHit !== self else { return nil }
            if nativeHit === hostedInspectorHit.pageView ||
                nativeHit.isDescendant(of: hostedInspectorHit.pageView) {
                return nil
            }
            if nativeHit === hostedInspectorHit.inspectorView ||
                nativeHit.isDescendant(of: hostedInspectorHit.inspectorView) {
                return nativeHit
            }
            if hostedInspectorHit.inspectorView.isDescendant(of: nativeHit),
               !(hostedInspectorHit.pageView === nativeHit || hostedInspectorHit.pageView.isDescendant(of: nativeHit)) {
                return nativeHit
            }
            return nil
        }

        func hostedInspectorDividerHit(at point: NSPoint) -> HostedInspectorDividerHit? {
            guard let hit = hostedInspectorDividerCandidate(),
                  hostedInspectorDividerHitRect(for: hit).contains(point) else {
                return nil
            }
            return hit
        }

        func hostedInspectorDividerCandidate() -> HostedInspectorDividerHit? {
            hostedInspectorDividerCandidate(in: self)
        }

        func hostedInspectorDividerCandidate(in root: NSView) -> HostedInspectorDividerHit? {
            if let preferredHit = hostedInspectorDividerCandidateUsingKnownWebViews(in: root) {
                return preferredHit
            }

            let inspectorCandidates = Self.visibleDescendants(in: root)
                .filter { Self.isVisibleHostedInspectorCandidate($0) && Self.isInspectorView($0) }
                .sorted { lhs, rhs in
                    let lhsFrame = root.convert(lhs.bounds, from: lhs)
                    let rhsFrame = root.convert(rhs.bounds, from: rhs)
                    return lhsFrame.minX < rhsFrame.minX
                }

            var bestHit: HostedInspectorDividerHit?
            var bestScore = -CGFloat.greatestFiniteMagnitude

            for inspectorCandidate in inspectorCandidates {
                guard let candidate = hostedInspectorDividerCandidate(in: root, startingAt: inspectorCandidate) else {
                    continue
                }
                let score = hostedInspectorDividerCandidateScore(candidate)
                if score > bestScore {
                    bestScore = score
                    bestHit = candidate
                }
            }

            return bestHit
        }

        func hostedInspectorDividerCandidateUsingKnownWebViews(in root: NSView) -> HostedInspectorDividerHit? {
            guard let pageLeaf = hostedWebView,
                  let inspectorLeaf = hostedInspectorFrontendWebView,
                  pageLeaf.isDescendant(of: root),
                  inspectorLeaf.isDescendant(of: root),
                  Self.isVisibleHostedInspectorCandidate(inspectorLeaf) else {
                return nil
            }
            return hostedInspectorDividerCandidate(
                in: root,
                pageLeaf: pageLeaf,
                inspectorLeaf: inspectorLeaf
            )
        }

        func hostedInspectorDividerCandidate(
            in root: NSView,
            pageLeaf: NSView,
            inspectorLeaf: NSView
        ) -> HostedInspectorDividerHit? {
            var currentInspector: NSView? = inspectorLeaf

            while let inspectorView = currentInspector, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }
                guard containerView === root || containerView.isDescendant(of: root) else {
                    currentInspector = containerView
                    continue
                }
                guard let pageView = Self.directChild(of: containerView, containing: pageLeaf) else {
                    currentInspector = containerView
                    continue
                }
                guard pageView !== inspectorView,
                      Self.isVisibleHostedInspectorSiblingCandidate(pageView),
                      Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame) > 8,
                      let dockSide = HostedInspectorDockSide.resolve(
                          pageFrame: pageView.frame,
                          inspectorFrame: inspectorView.frame
                      ) else {
                    currentInspector = containerView
                    continue
                }
                return HostedInspectorDividerHit(
                    containerView: containerView,
                    pageView: pageView,
                    inspectorView: inspectorView,
                    dockSide: dockSide
                )
            }

            return nil
        }

        func hostedInspectorDividerHitRect(for hit: HostedInspectorDividerHit) -> NSRect {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            return hit.dockSide.dividerHitRect(
                in: bounds,
                pageFrame: pageFrame,
                inspectorFrame: inspectorFrame,
                expansion: Self.hostedInspectorDividerHitExpansion
            )
        }

        func hostedInspectorDividerCandidate(in root: NSView, startingAt inspectorLeaf: NSView) -> HostedInspectorDividerHit? {
            var current: NSView? = inspectorLeaf
            var bestHit: HostedInspectorDividerHit?

            while let inspectorView = current, inspectorView !== root {
                guard let containerView = inspectorView.superview else { break }

                let pageCandidates = containerView.subviews.compactMap { candidate -> (view: NSView, dockSide: HostedInspectorDockSide)? in
                    guard Self.isVisibleHostedInspectorSiblingCandidate(candidate) else { return nil }
                    guard candidate !== inspectorView else { return nil }
                    guard Self.verticalOverlap(between: candidate.frame, and: inspectorView.frame) > 8 else {
                        return nil
                    }
                    guard let dockSide = HostedInspectorDockSide.resolve(
                        pageFrame: candidate.frame,
                        inspectorFrame: inspectorView.frame
                    ) else {
                        return nil
                    }
                    return (view: candidate, dockSide: dockSide)
                }

                if let pageCandidate = pageCandidates.max(by: {
                    hostedInspectorPageCandidateScore($0.view, inspectorView: inspectorView)
                        < hostedInspectorPageCandidateScore($1.view, inspectorView: inspectorView)
                }) {
                    bestHit = HostedInspectorDividerHit(
                        containerView: containerView,
                        pageView: pageCandidate.view,
                        inspectorView: inspectorView,
                        dockSide: pageCandidate.dockSide
                    )
                }

                current = containerView
            }

            return bestHit
        }

        private func hostedInspectorDividerCandidateScore(_ hit: HostedInspectorDividerHit) -> CGFloat {
            let pageFrame = convert(hit.pageView.bounds, from: hit.pageView)
            let inspectorFrame = convert(hit.inspectorView.bounds, from: hit.inspectorView)
            let overlap = Self.verticalOverlap(between: pageFrame, and: inspectorFrame)
            let coverageWidth = max(pageFrame.maxX, inspectorFrame.maxX) - min(pageFrame.minX, inspectorFrame.minX)
            return (overlap * 1_000) + coverageWidth + pageFrame.width
        }

        private func hostedInspectorPageCandidateScore(_ pageView: NSView, inspectorView: NSView) -> CGFloat {
            let overlap = Self.verticalOverlap(between: pageView.frame, and: inspectorView.frame)
            let coverageWidth = max(pageView.frame.maxX, inspectorView.frame.maxX) - min(pageView.frame.minX, inspectorView.frame.minX)
            return (overlap * 1_000) + coverageWidth + pageView.frame.width
        }

        func scheduleHostedInspectorDividerReapply(reason: String) {
            hostedInspectorReapplyWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hostedInspectorReapplyWorkItem = nil
                _ = self.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded()
                if self.hasStoredHostedInspectorWidthPreference {
                    self.reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: reason)
                } else {
                    self.captureHostedInspectorPreferredWidthFromCurrentLayout(reason: reason)
                }
            }
            hostedInspectorReapplyWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        func captureHostedInspectorPreferredWidthFromCurrentLayout(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard !isHostedInspectorDividerDragActive else { return }
            guard let hit = hostedInspectorDividerCandidate() else {
#if DEBUG
                if !hasLoggedMissingHostedInspectorCandidate {
                    hasLoggedMissingHostedInspectorCandidate = true
                    let preferredWidthDesc = preferredHostedInspectorWidth.map {
                        String(format: "%.1f", $0)
                    } ?? "nil"
                    cmuxDebugLog(
                        "browser.panel.hostedInspector stage=\(reason).captureMissingCandidate " +
                        "host=\(Self.debugObjectID(self)) preferredWidth=\(preferredWidthDesc)"
                    )
                }
#endif
                return
            }

            let inspectorWidth = max(0, hit.inspectorView.frame.width)
            guard inspectorWidth > 1 else { return }
            recordHostedInspectorSideDockWidth(inspectorWidth)
            let currentFraction: CGFloat? = {
                guard hit.containerView.bounds.width > 0 else { return nil }
                return inspectorWidth / hit.containerView.bounds.width
            }()
            let widthMatches = preferredHostedInspectorWidth.map {
                abs($0 - inspectorWidth) <= 0.5
            } ?? false
            let fractionMatches: Bool = {
                switch (preferredHostedInspectorWidthFraction, currentFraction) {
                case (nil, nil):
                    return true
                case let (lhs?, rhs?):
                    return abs(lhs - rhs) <= 0.001
                default:
                    return false
                }
            }()
            guard !(widthMatches && fractionMatches) else { return }

#if DEBUG
            hasLoggedMissingHostedInspectorCandidate = false
#endif
            recordPreferredHostedInspectorWidth(
                inspectorWidth,
                containerBounds: hit.containerView.bounds
            )
        }

        func reapplyHostedInspectorDividerToStoredWidthIfNeeded(reason: String) {
            guard !isApplyingHostedInspectorLayout else { return }
            guard let hit = hostedInspectorDividerCandidate() else { return }
            guard let preferredWidth = resolvedPreferredHostedInspectorWidth(in: hit.containerView.bounds) else {
                return
            }
            let currentInspectorWidth = max(0, hit.inspectorView.frame.width)
            guard abs(currentInspectorWidth - preferredWidth) > 0.5 else { return }
            _ = applyHostedInspectorDividerWidth(
                preferredWidth,
                to: hit,
                minimumInspectorWidth: Self.minimumHostedInspectorWidth,
                reason: reason
            )
        }

        @discardableResult
        func applyHostedInspectorDividerWidth(
            _ preferredWidth: CGFloat,
            to hit: HostedInspectorDividerHit,
            minimumInspectorWidth: CGFloat,
            reason: String
        ) -> (pageFrame: NSRect, inspectorFrame: NSRect) {
            let containerBounds = hit.containerView.bounds
            let nextFrames = hit.dockSide.resizedFrames(
                preferredWidth: preferredWidth,
                in: containerBounds,
                pageFrame: hit.pageView.frame,
                inspectorFrame: hit.inspectorView.frame,
                minimumInspectorWidth: minimumInspectorWidth
            )
            let pageFrame = nextFrames.pageFrame
            let inspectorFrame = nextFrames.inspectorFrame

            let oldPageFrame = hit.pageView.frame
            let oldInspectorFrame = hit.inspectorView.frame
            let pageChanged = !Self.rectApproximatelyEqual(pageFrame, oldPageFrame, epsilon: 0.5)
            let inspectorChanged = !Self.rectApproximatelyEqual(inspectorFrame, oldInspectorFrame, epsilon: 0.5)
            guard pageChanged || inspectorChanged else {
                return (pageFrame, inspectorFrame)
            }
            recordHostedInspectorSideDockWidth(inspectorFrame.width)

            isApplyingHostedInspectorLayout = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hit.pageView.frame = pageFrame
            hit.inspectorView.frame = inspectorFrame
            CATransaction.commit()
            isApplyingHostedInspectorLayout = false

            hit.pageView.needsDisplay = true
            hit.pageView.setNeedsDisplay(hit.pageView.bounds)
            hit.inspectorView.needsDisplay = true
            hit.inspectorView.setNeedsDisplay(hit.inspectorView.bounds)
            hit.containerView.needsDisplay = true
            hit.containerView.setNeedsDisplay(hit.containerView.bounds)
            if let localInlineSlotView {
                localInlineSlotView.needsDisplay = true
                localInlineSlotView.setNeedsDisplay(localInlineSlotView.bounds)
            }
            needsDisplay = true
            setNeedsDisplay(bounds)

            let isLiveDrag = reason == "drag"
#if DEBUG
            cmuxDebugLog(
                "browser.panel.hostedInspector stage=\(reason).reapply " +
                "host=\(Self.debugObjectID(self)) preferredWidth=\(String(format: "%.1f", preferredWidth)) " +
                "liveDrag=\(isLiveDrag ? 1 : 0) " +
                "pageChanged=\(pageChanged ? 1 : 0) inspectorChanged=\(inspectorChanged ? 1 : 0) " +
                "oldPage=\(Self.debugRect(oldPageFrame)) oldInspector=\(Self.debugRect(oldInspectorFrame)) " +
                "container=\(Self.debugObjectID(hit.containerView)) " +
                "pageFrame=\(Self.debugRect(pageFrame)) inspectorFrame=\(Self.debugRect(inspectorFrame))"
            )
#endif
            return (pageFrame, inspectorFrame)
        }

        private static func visibleDescendants(in root: NSView) -> [NSView] {
            var descendants: [NSView] = []
            var stack = Array(root.subviews.reversed())
            while let view = stack.popLast() {
                descendants.append(view)
                stack.append(contentsOf: view.subviews.reversed())
            }
            return descendants
        }

        static func directChild(of container: NSView, containing descendant: NSView) -> NSView? {
            var current: NSView? = descendant
            var directChild: NSView?
            while let view = current, view !== container {
                directChild = view
                current = view.superview
            }
            guard current === container else { return nil }
            return directChild
        }

        fileprivate static func isInspectorView(_ view: NSView) -> Bool {
            cmuxIsWebInspectorObject(view)
        }

        fileprivate static func isVisibleHostedInspectorCandidate(_ view: NSView) -> Bool {
            !view.isHidden &&
                view.alphaValue > 0 &&
                view.frame.width > 1 &&
                view.frame.height > 1
        }

        private static func isVisibleHostedInspectorSiblingCandidate(_ view: NSView) -> Bool {
            !view.isHidden &&
                view.alphaValue > 0 &&
                view.frame.height > 1
        }

        private static func verticalOverlap(between lhs: NSRect, and rhs: NSRect) -> CGFloat {
            max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        }
}
