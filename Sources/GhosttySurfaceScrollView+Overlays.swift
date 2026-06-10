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


// MARK: - Flash, notification ring, badges, image transfer indicator
extension GhosttySurfaceScrollView {
    enum FlashStyle {
        case navigation
        case notification
    }

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> FlashStyle {
        switch reason {
        case .navigation:
            return .navigation
        case .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return .notification
        }
    }

    private static func flashPresentation(for style: FlashStyle) -> WorkspaceAttentionFlashPresentation {
        switch style {
        case .navigation:
            return WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        case .notification:
            return WorkspaceAttentionCoordinator.flashStyle(for: .notificationArrival)
        }
    }

    enum NotificationRingMetrics {
        static let inset = PanelOverlayRingMetrics.inset
        static let cornerRadius = PanelOverlayRingMetrics.cornerRadius
        static let lineWidth = PanelOverlayRingMetrics.lineWidth
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    func setInactiveOverlay(color: NSColor, opacity: CGFloat, visible: Bool) {
        let clampedOpacity = max(0, min(1, opacity))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inactiveOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedOpacity).cgColor
        inactiveOverlayView.isHidden = !(visible && clampedOpacity > 0.0001)
        CATransaction.commit()
    }

    func setNotificationRing(visible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNotificationRing(visible: visible)
            }
            return
        }

        let targetHidden = !visible
        let targetOpacity: Float = visible ? 1 : 0
        guard notificationRingOverlayView.isHidden != targetHidden ||
                notificationRingLayer.opacity != targetOpacity else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingOverlayView.isHidden = targetHidden
        notificationRingLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    private func cancelImageTransferIndicatorShow() {
        imageTransferIndicatorShowWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem = nil
    }

    private func updateImageTransferIndicatorZOrder(relativeTo overlay: NSView?) {
        guard !imageTransferIndicatorContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: overlay)
            return
        }
        if keyboardCopyModeBadgeContainerView.superview === self,
           !keyboardCopyModeBadgeContainerView.isHidden {
            addSubview(
                imageTransferIndicatorContainerView,
                positioned: .above,
                relativeTo: keyboardCopyModeBadgeContainerView
            )
            return
        }
        addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: nil)
    }

    func updateKeyboardCopyModeBadgeZOrder(relativeTo overlay: NSView?) {
        guard !keyboardCopyModeBadgeContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: overlay)
        } else {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: nil)
        }
        updateImageTransferIndicatorZOrder(relativeTo: overlay)
    }

    @objc func handleImageTransferCancel() {
        guard let operation = activeImageTransferOperation else { return }
        let onCancel = activeImageTransferCancelHandler
        guard operation.cancel() else { return }
        endImageTransferIndicator(for: operation)
        onCancel?()
    }

    func beginImageTransferIndicator(
        for operation: TerminalImageTransferOperation,
        onCancel: @escaping () -> Void
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginImageTransferIndicator(for: operation, onCancel: onCancel)
            }
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = operation
        activeImageTransferCancelHandler = onCancel
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activeImageTransferOperation === operation else { return }
            guard !operation.isCancelled else { return }
            self.imageTransferIndicatorShowWorkItem = nil
            self.imageTransferIndicatorSpinner.startAnimation(nil)
            self.imageTransferIndicatorContainerView.isHidden = false
            self.updateImageTransferIndicatorZOrder(relativeTo: self.searchOverlayHostingView)
        }
        imageTransferIndicatorShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func endImageTransferIndicator(for operation: TerminalImageTransferOperation?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.endImageTransferIndicator(for: operation)
            }
            return
        }

        if let operation,
           activeImageTransferOperation !== operation {
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = nil
        activeImageTransferCancelHandler = nil
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true
    }

    func syncKeyStateIndicator(text: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.syncKeyStateIndicator(text: text)
            }
            return
        }

        if let text, !text.isEmpty {
            keyboardCopyModeBadgeLabel.stringValue = text
            keyboardCopyModeBadgeIconView.setAccessibilityLabel(text)
            let needsReorder = keyboardCopyModeBadgeContainerView.isHidden
                || keyboardCopyModeBadgeContainerView.superview !== self
                || subviews.last !== keyboardCopyModeBadgeContainerView
            keyboardCopyModeBadgeContainerView.isHidden = false
            if needsReorder {
                updateKeyboardCopyModeBadgeZOrder(relativeTo: searchOverlayHostingView)
            }
            return
        }

        keyboardCopyModeBadgeIconView.setAccessibilityLabel(terminalKeyTableIndicatorAccessibilityLabel)
        keyboardCopyModeBadgeContainerView.isHidden = true
    }

    func triggerFlash(style: FlashStyle = .navigation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastFlashStyle = style
            #if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath(style: style)
            self.updateFlashAppearance(style: style)
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = FocusFlashPattern.values.map { NSNumber(value: $0) }
            animation.keyTimes = FocusFlashPattern.keyTimes.map { NSNumber(value: $0) }
            animation.duration = FocusFlashPattern.duration
            animation.timingFunctions = FocusFlashPattern.curves.map { curve in
                switch curve {
                case .easeIn:
                    return CAMediaTimingFunction(name: .easeIn)
                case .easeOut:
                    return CAMediaTimingFunction(name: .easeOut)
                }
            }
            self.flashLayer.add(animation, forKey: "cmux.flash")
        }
    }

    func updateNotificationRingPath() {
        updateOverlayRingPath(
            layer: notificationRingLayer,
            bounds: notificationRingOverlayView.bounds,
            inset: NotificationRingMetrics.inset,
            radius: NotificationRingMetrics.cornerRadius
        )
    }

    func updateFlashPath(style: FlashStyle) {
        let inset: CGFloat
        let radius: CGFloat
        switch style {
        case .navigation, .notification:
            inset = NotificationRingMetrics.inset
            radius = NotificationRingMetrics.cornerRadius
        }
        updateOverlayRingPath(
            layer: flashLayer,
            bounds: flashOverlayView.bounds,
            inset: inset,
            radius: radius
        )
    }

    func updateFlashAppearance(style: FlashStyle) {
        let presentation = Self.flashPresentation(for: style)
        let strokeColor = presentation.accent.strokeColor
        flashLayer.strokeColor = strokeColor.cgColor
        flashLayer.shadowColor = strokeColor.cgColor
        flashLayer.shadowOpacity = Float(presentation.glowOpacity)
        flashLayer.shadowRadius = presentation.glowRadius
    }

    private func updateOverlayRingPath(
        layer: CAShapeLayer,
        bounds: CGRect,
        inset: CGFloat,
        radius: CGFloat
    ) {
        layer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            layer.path = nil
            return
        }
        let rect = PanelOverlayRingMetrics.pathRect(in: bounds)
        layer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

}
