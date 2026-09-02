import AppKit
import QuartzCore

/// Layer-backed window fill installed below the hosting and portal trees.
@MainActor
final class WindowRootBackdropView: NSView {
    private let exclusionMaskLayer = CAShapeLayer()
    private weak var installedReferenceView: NSView?
    private var installationConstraints: [NSLayoutConstraint] = []
    private var exclusionRectsInWindow: [NSRect] = []
    private var backdropColorIsOpaque = false
    private var hasVisibleExclusions = false
    /// Changes whenever exclusion or installation geometry inputs change, so
    /// repeated AppKit layout callbacks can skip rebuilding the mask path.
    private var maskInputGeneration: UInt64 = 0
    private var lastBuiltMaskInputGeneration: UInt64?
    private var lastMaskBounds: NSRect?
    private var lastMaskLayerBounds: CGRect?
    private var lastMaskFrameInWindow: NSRect?
    private var lastMaskWindowID: ObjectIdentifier?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("cmux.windowRootBackdrop")
        wantsLayer = true
        layer?.masksToBounds = true
        exclusionMaskLayer.fillRule = .evenOdd
        exclusionMaskLayer.fillColor = NSColor.black.cgColor
        layer?.mask = exclusionMaskLayer
        rebuildExclusionMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        backdropColorIsOpaque && !hasVisibleExclusions
    }

    override func layout() {
        super.layout()
        rebuildExclusionMask()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildExclusionMask()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Installs the root immediately below the resolver's content reference.
    func install(in target: WindowContentOverlayInstallationTarget) {
        let needsReinstallation =
            superview !== target.container || installedReferenceView !== target.reference
        var didChangeInstallation = false
        if needsReinstallation {
            NSLayoutConstraint.deactivate(installationConstraints)
            installationConstraints.removeAll()
            removeFromSuperview()
            translatesAutoresizingMaskIntoConstraints = false
            target.container.addSubview(self, positioned: .below, relativeTo: target.reference)
            installationConstraints = [
                topAnchor.constraint(equalTo: target.reference.topAnchor),
                bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installationConstraints)
            installedReferenceView = target.reference
            didChangeInstallation = true
        } else if let rootIndex = target.container.subviews.firstIndex(of: self),
                  let referenceIndex = target.container.subviews.firstIndex(of: target.reference),
                  rootIndex != referenceIndex - 1 {
            // Fallback glass is inserted below the reference after the root may
            // already be installed. Reassert adjacency so the shared backdrop
            // remains above that fallback layer and directly below content.
            target.container.addSubview(self, positioned: .below, relativeTo: target.reference)
            didChangeInstallation = true
        }

        guard didChangeInstallation else { return }
        maskInputGeneration &+= 1
        needsLayout = true
        rebuildExclusionMask()
    }

    /// Applies the resolved root policy without enabling Core Image compositing.
    func apply(
        policy: WindowBackdropPolicy,
        hostingPhase: WindowBackdropHostingPhase
    ) {
        let color: NSColor
        switch policy {
        case let .ghosttyTerminalBackdrop(backgroundColor, opacity, _):
            let clampedOpacity = WindowAppearanceSnapshot.clampedOpacity(Double(opacity))
            let backdropColor = backgroundColor.withAlphaComponent(clampedOpacity)
            color = hostingPhase == .opaqueRootBackdrop
                ? WindowChromeColorResolver().compositedColor(backdropColor, over: .windowBackgroundColor)
                : backdropColor
        case .sidebarMaterial, .clear:
            color = .clear
        }

        backdropColorIsOpaque = color.alphaComponent >= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color.cgColor
        layer?.isOpaque = isOpaque
        CATransaction.commit()
    }

    /// Replaces the pane rectangles that must reveal the layer below this root.
    func updateExclusionRectsInWindow(_ rects: [NSRect]) {
        let normalized = rects
            .map(\.standardized)
            .filter(isFiniteVisibleRect)
            .sorted(by: rectSortsBefore)
        guard normalized != exclusionRectsInWindow else { return }
        exclusionRectsInWindow = normalized
        maskInputGeneration &+= 1
        rebuildExclusionMask()
    }

    private func rebuildExclusionMask() {
        guard let rootLayer = layer else { return }
        let currentWindowID = window.map(ObjectIdentifier.init)
        let currentFrameInWindow: NSRect? = window == nil
            ? nil
            : convert(bounds, to: nil).standardized
        let inputsUnchanged =
            lastBuiltMaskInputGeneration == maskInputGeneration &&
            lastMaskBounds == bounds &&
            lastMaskLayerBounds == rootLayer.bounds &&
            lastMaskFrameInWindow == currentFrameInWindow &&
            lastMaskWindowID == currentWindowID
        guard !inputsUnchanged else { return }

        let localRects: [NSRect]
        if window == nil {
            localRects = []
        } else {
            localRects = exclusionRectsInWindow.compactMap { rectInWindow in
                let localRect = convert(rectInWindow, from: nil).standardized
                let clipped = localRect.intersection(bounds)
                return isFiniteVisibleRect(clipped) ? clipped : nil
            }
        }
        let path = CGMutablePath()
        if isFiniteVisibleRect(bounds) {
            path.addRect(bounds)
        }
        if !localRects.isEmpty {
            // Normalize once so overlapping panes form one union contour before
            // that contour becomes an even-odd hole in the outer bounds.
            let exclusions = CGMutablePath()
            exclusions.addRects(localRects)
            path.addPath(exclusions.normalized(using: .winding))
        }

        hasVisibleExclusions = !localRects.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        exclusionMaskLayer.frame = rootLayer.bounds
        exclusionMaskLayer.path = path
        rootLayer.isOpaque = isOpaque
        CATransaction.commit()

        lastBuiltMaskInputGeneration = maskInputGeneration
        lastMaskBounds = bounds
        lastMaskLayerBounds = rootLayer.bounds
        lastMaskFrameInWindow = currentFrameInWindow
        lastMaskWindowID = currentWindowID
    }

    private func isFiniteVisibleRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.size.width.isFinite &&
            rect.size.height.isFinite &&
            !rect.isNull &&
            rect.width > 0 &&
            rect.height > 0
    }

    private func rectSortsBefore(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
        if lhs.maxY != rhs.maxY { return lhs.maxY < rhs.maxY }
        return lhs.maxX < rhs.maxX
    }
}
