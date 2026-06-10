import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Scrollbar synchronization and live scroll
extension GhosttySurfaceScrollView {
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard scrollView.hasVerticalScroller,
              NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        if let scrollbarTrackingArea {
            removeTrackingArea(scrollbarTrackingArea)
            self.scrollbarTrackingArea = nil
        }

        super.updateTrackingAreas()

        guard scrollView.hasVerticalScroller,
              let scroller = scrollView.verticalScroller else { return }

        let trackingArea = NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        scrollbarTrackingArea = trackingArea
    }

    func synchronizeScrollView() {
        var didChangeGeometry = false
        let targetDocumentHeight = documentHeight()
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)

                // Check if we're currently at the bottom (with threshold for float drift)
                let currentOrigin = scrollView.contentView.bounds.origin
                let documentHeight = documentView.frame.height
                let viewportHeight = scrollView.contentView.bounds.height
                let distanceFromBottom = documentHeight - currentOrigin.y - viewportHeight
                let isAtBottom = distanceFromBottom <= Self.scrollToBottomThreshold

                // Update userScrolledAwayFromBottom based on current position
                if isAtBottom {
                    userScrolledAwayFromBottom = false
                }

                // Passive bottom packets should not override an explicit scrollback review,
                // but the first scrollbar packet caused by the user's own wheel input should
                // still move the viewport to the requested scrollback position.
                let shouldAutoScroll = !userScrolledAwayFromBottom || allowExplicitScrollbarSync

                if shouldAutoScroll && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    scrollView.contentView.scroll(to: targetOrigin)
                    didChangeGeometry = true
                }
                lastSentRow = Int(scrollbar.offset)
            }
        }

        allowExplicitScrollbarSync = false

        if didChangeGeometry {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func handleScrollChange() {
        synchronizeSurfaceView()
    }

    func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height

        // Track if user has scrolled away from bottom to review scrollback
        if scrollOffset > Self.scrollToBottomThreshold {
            userScrolledAwayFromBottom = true
        } else if scrollOffset <= 0 {
            userScrolledAwayFromBottom = false
        }

        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        let wasVisible = scrollView.hasVerticalScroller
        if pendingExplicitWheelScroll {
            userScrolledAwayFromBottom = scrollbar.offset + scrollbar.len < scrollbar.total
            allowExplicitScrollbarSync = true
            pendingExplicitWheelScroll = false
        }
        surfaceView.scrollbar = scrollbar
        let isVisible = shouldShowTerminalScrollBar()
        if wasVisible != isVisible {
            _ = synchronizeGeometryAndContent()
            return
        }
        synchronizeScrollView()
    }

    @discardableResult
    func synchronizeScrollbarAppearance() -> Bool {
        let shouldShowScrollBar = shouldShowTerminalScrollBar()
        let didChange =
            scrollView.hasVerticalScroller != shouldShowScrollBar ||
            scrollView.autohidesScrollers != false ||
            scrollView.scrollerStyle != .overlay
        scrollView.hasVerticalScroller = shouldShowScrollBar
        // Mirror upstream Ghostty: keep overlay scrollers even when the
        // system preference is legacy so terminal content never sits beneath a
        // permanently reserved scrollbar gutter.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        updateTrackingAreas()
        return didChange
    }

    func handlePreferredScrollerStyleChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePreferredScrollerStyleChange()
            }
            return
        }

        synchronizeScrollbarAppearance()

        // Retile just the scroll view so contentSize reflects the current
        // scroller preference without perturbing hosted terminal geometry.
        scrollView.tile()
        _ = synchronizeCoreSurface()
    }

    func handleTerminalScrollBarPreferenceChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleTerminalScrollBarPreferenceChange()
            }
            return
        }

        _ = synchronizeGeometryAndContent()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }

    private func terminalScrollBarAllowedBySettings() -> Bool {
        guard GhosttyApp.shared.scrollbarVisibility() != .never else { return false }
        guard TerminalScrollBarSettings.isVisible() else { return false }
        return true
    }

    private func surfaceHasScrollback() -> Bool? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        // Embedded Ghostty exposes alternate-screen TUIs to the wrapper as a
        // viewport with no additional scrollback (`total <= len`). Treat that
        // as the signal to suppress the overlay scrollbar so full-screen apps
        // like nvim/htop do not pin it on top of the rightmost cell column.
        return scrollbar.total > scrollbar.len
    }

    private func shouldShowTerminalScrollBar() -> Bool {
        guard terminalScrollBarAllowedBySettings() else { return false }
        guard let hasScrollback = surfaceHasScrollback() else {
            // Ghostty reports scrollback asynchronously. Until the first packet
            // arrives, keep the scroller visible so restored/reattached
            // surfaces with existing scrollback do not appear broken.
            return true
        }
        return hasScrollback
    }

}
