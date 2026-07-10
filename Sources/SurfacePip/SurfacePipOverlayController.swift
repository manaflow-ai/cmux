import AppKit
import SwiftUI

@MainActor
final class SurfacePipOverlayController: NSObject {
    enum Corner: String {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    private static let minimumSize = NSSize(width: 240, height: 160)
    private static let edgeInset: CGFloat = 16

    let panelId: UUID
    let hostingWindowId: UUID

    private weak var window: NSWindow?
    let containerView: SurfacePipOverlayContainerView
    private let hostingView: NSHostingView<SurfacePipHostView>
    private let chromeComposition = AppWindowChromeComposition()
    private let onRequestReturn: (UUID) -> Void
    private let onHostingWindowWillClose: (UUID) -> Void
    private let onRequestFocus: (UUID) -> Void
    private let onFrameChanged: (NSRect, Corner) -> Void
    private var closeObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var frameInReference: NSRect
    private var stickyCorner: Corner
    private var isClosingForReturn = false

    init(
        panelId: UUID,
        hostingWindowId: UUID,
        window: NSWindow,
        title: String,
        frame: NSRect,
        corner: Corner,
        contentView: SurfacePipHostView,
        onRequestReturn: @escaping (UUID) -> Void,
        onHostingWindowWillClose: @escaping (UUID) -> Void,
        onRequestFocus: @escaping (UUID) -> Void,
        onFrameChanged: @escaping (NSRect, Corner) -> Void
    ) {
        self.panelId = panelId
        self.hostingWindowId = hostingWindowId
        self.window = window
        self.containerView = SurfacePipOverlayContainerView(title: title)
        self.hostingView = NSHostingView(rootView: contentView)
        self.frameInReference = frame
        self.stickyCorner = corner
        self.onRequestReturn = onRequestReturn
        self.onHostingWindowWillClose = onHostingWindowWillClose
        self.onRequestFocus = onRequestFocus
        self.onFrameChanged = onFrameChanged
        super.init()

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.contentView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.contentView.trailingAnchor),
        ])

        containerView.onMoveDelta = { [weak self] delta in
            self?.move(by: delta)
        }
        containerView.onResizeDelta = { [weak self] delta in
            self?.resize(by: delta)
        }
        containerView.onInteractionEnded = { [weak self] in
            self?.snapToNearestCorner(animated: true)
        }
        containerView.onRequestFocus = { [weak self] in
            guard let self else { return }
            self.onRequestFocus(self.panelId)
        }
        containerView.onRequestReturn = { [weak self] in
            guard let self else { return }
            self.onRequestReturn(self.panelId)
        }

        installWindowObservers(for: window)
        _ = ensureInstalled()
    }

    var windowRelativeFrame: NSRect {
        guard let reference = installedReferenceView,
              let container = installedContainerView,
              containerView.superview === container else {
            return frameInReference
        }
        return reference.convert(containerView.frame, from: container)
    }

    func show() {
        guard ensureInstalled() else { return }
        bringToFront()
        onRequestFocus(panelId)
    }

    func closeForReturn() {
        guard !isClosingForReturn else { return }
        isClosingForReturn = true
        removeWindowObservers()
        containerView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

    private func installWindowObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        closeObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosingForReturn else { return }
                self.onHostingWindowWillClose(self.panelId)
            }
        }
        resizeObserver = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reclampToStickyCorner()
            }
        }
    }

    private func removeWindowObservers() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition
                .contentOverlayTargetResolver
                .installationTarget(for: window) else { return false }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
            installedContainerView = target.container
            installedReferenceView = target.reference
        }

        let clamped = clampedFrame(frameInReference, in: target.reference.bounds)
        applyFrameInReference(clamped)
        return true
    }

    private func bringToFront() {
        guard let container = installedContainerView, containerView.superview === container else { return }
        container.addSubview(containerView, positioned: .above, relativeTo: nil)
    }

    private func move(by delta: NSSize) {
        guard let reference = installedReferenceView else { return }
        var next = windowRelativeFrame
        next.origin.x += delta.width
        next.origin.y += delta.height
        next = clampedFrame(next, in: reference.bounds)
        stickyCorner = nearestCorner(for: next, in: reference.bounds)
        applyFrameInReference(next)
        onFrameChanged(next, stickyCorner)
    }

    private func resize(by delta: NSSize) {
        guard let reference = installedReferenceView else { return }
        var next = windowRelativeFrame
        next.size.width += delta.width
        next.size.height -= delta.height
        next.origin.y += delta.height
        next = clampedFrame(next, in: reference.bounds)
        stickyCorner = nearestCorner(for: next, in: reference.bounds)
        applyFrameInReference(next)
        onFrameChanged(next, stickyCorner)
    }

    private func reclampToStickyCorner() {
        guard ensureInstalled(), let reference = installedReferenceView else { return }
        let next = frame(for: stickyCorner, size: frameInReference.size, in: reference.bounds)
        applyFrameInReference(next)
        onFrameChanged(next, stickyCorner)
    }

    private func snapToNearestCorner(animated: Bool) {
        guard let reference = installedReferenceView else { return }
        let current = windowRelativeFrame
        let corner = nearestCorner(for: current, in: reference.bounds)
        let target = frame(for: corner, size: current.size, in: reference.bounds)
        stickyCorner = corner
        applyFrameInReference(target, animated: animated)
        onFrameChanged(target, corner)
    }

    private func applyFrameInReference(_ frame: NSRect, animated: Bool = false) {
        guard let reference = installedReferenceView,
              let container = installedContainerView else {
            frameInReference = frame
            return
        }
        let frameInContainer = container.convert(frame, from: reference)
        frameInReference = frame
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                containerView.animator().frame = frameInContainer
            } completionHandler: { [weak self] in
                self?.bringToFront()
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView.frame = frameInContainer
            CATransaction.commit()
            bringToFront()
        }
    }

    private func clampedFrame(_ proposed: NSRect, in bounds: NSRect) -> NSRect {
        guard bounds.width > 1, bounds.height > 1 else { return proposed }
        let availableWidth = max(1, bounds.width - Self.edgeInset * 2)
        let availableHeight = max(1, bounds.height - Self.edgeInset * 2)
        let maximumWidth = min(availableWidth, max(Self.minimumSize.width, bounds.width / 2))
        let maximumHeight = min(availableHeight, max(Self.minimumSize.height, bounds.height / 2))
        let width = min(max(Self.minimumSize.width, proposed.width), maximumWidth)
        let height = min(max(Self.minimumSize.height, proposed.height), maximumHeight)
        let minX = bounds.minX + Self.edgeInset
        let minY = bounds.minY + Self.edgeInset
        let maxX = max(minX, bounds.maxX - Self.edgeInset - width)
        let maxY = max(minY, bounds.maxY - Self.edgeInset - height)
        return NSRect(
            x: min(max(proposed.origin.x, minX), maxX),
            y: min(max(proposed.origin.y, minY), maxY),
            width: width,
            height: height
        )
    }

    private func frame(for corner: Corner, size: NSSize, in bounds: NSRect) -> NSRect {
        let normalized = clampedFrame(NSRect(origin: .zero, size: size), in: bounds)
        let width = normalized.width
        let height = normalized.height
        let leadingX = bounds.minX + Self.edgeInset
        let trailingX = bounds.maxX - Self.edgeInset - width
        let bottomY = bounds.minY + Self.edgeInset
        let topY = bounds.maxY - Self.edgeInset - height

        switch corner {
        case .topLeading:
            return clampedFrame(NSRect(x: leadingX, y: topY, width: width, height: height), in: bounds)
        case .topTrailing:
            return clampedFrame(NSRect(x: trailingX, y: topY, width: width, height: height), in: bounds)
        case .bottomLeading:
            return clampedFrame(NSRect(x: leadingX, y: bottomY, width: width, height: height), in: bounds)
        case .bottomTrailing:
            return clampedFrame(NSRect(x: trailingX, y: bottomY, width: width, height: height), in: bounds)
        }
    }

    private func nearestCorner(for frame: NSRect, in bounds: NSRect) -> Corner {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let horizontalTrailing = center.x >= bounds.midX
        let verticalTop = center.y >= bounds.midY
        switch (horizontalTrailing, verticalTop) {
        case (false, true): return .topLeading
        case (true, true): return .topTrailing
        case (false, false): return .bottomLeading
        case (true, false): return .bottomTrailing
        }
    }
}
