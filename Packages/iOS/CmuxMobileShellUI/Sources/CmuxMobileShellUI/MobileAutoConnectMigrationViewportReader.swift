#if os(iOS)
import SwiftUI
import UIKit

/// Resolves the height the presented sheet can actually render inside its
/// scene, window, and presentation container.
struct MobileAutoConnectMigrationViewportGeometry {
    /// Intersects every UIKit frame after callers convert them into one
    /// coordinate space. Transient, empty presentation geometry is ignored.
    static func availableHeight(
        sceneFrame: CGRect,
        windowFrame: CGRect,
        containerFrame: CGRect?,
        presentedFrame: CGRect?,
        contentOriginY: CGFloat
    ) -> CGFloat? {
        guard contentOriginY.isFinite else { return nil }
        var visibleFrame = sceneFrame.standardized.intersection(windowFrame.standardized)
        guard Self.isUsable(visibleFrame) else { return nil }

        switch (containerFrame, presentedFrame) {
        case (nil, nil):
            break
        case let (containerFrame?, presentedFrame?):
            guard Self.isUsable(containerFrame), Self.isUsable(presentedFrame) else {
                return nil
            }
            visibleFrame = visibleFrame
                .intersection(containerFrame.standardized)
                .intersection(presentedFrame.standardized)
        case (.some, nil), (nil, .some):
            return nil
        }

        guard Self.isUsable(visibleFrame) else { return nil }
        let viewportTop = max(visibleFrame.minY, contentOriginY)
        let availableHeight = visibleFrame.maxY - viewportTop
        return availableHeight.isFinite && availableHeight > 0 ? availableHeight : nil
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && !frame.isEmpty
    }
}

/// A layout-neutral UIKit anchor that observes the enclosing presentation's
/// real visible frame. The system may clamp a fixed-height detent without
/// feeding that smaller proposal back into SwiftUI, so the sheet uses this
/// value as the ScrollView's explicit maximum height.
struct MobileAutoConnectMigrationViewportReader: UIViewRepresentable {
    let availableHeightDidChange: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> MobileAutoConnectMigrationViewportReaderView {
        let view = MobileAutoConnectMigrationViewportReaderView()
        view.isAccessibilityElement = false
        view.isUserInteractionEnabled = false
        view.availableHeightDidChange = availableHeightDidChange
        return view
    }

    func updateUIView(
        _ uiView: MobileAutoConnectMigrationViewportReaderView,
        context: Context
    ) {
        uiView.availableHeightDidChange = availableHeightDidChange
    }

    static func dismantleUIView(
        _ uiView: MobileAutoConnectMigrationViewportReaderView,
        coordinator: ()
    ) {
        uiView.stopReporting()
    }
}

/// Reports only when UIKit lays out a meaningfully different visible height,
/// keeping the measurement lifecycle-driven and preventing state churn.
final class MobileAutoConnectMigrationViewportReaderView: UIView {
    var availableHeightDidChange: (@MainActor (CGFloat) -> Void)?

    private var lastReportedHeight: CGFloat?
    private var pendingHeight: CGFloat?
    private var deliveryTask: Task<Void, Never>?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            resetReportingState()
            return
        }
        reportAvailableHeightIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportAvailableHeightIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportAvailableHeightIfNeeded()
    }

    func stopReporting() {
        resetReportingState()
        availableHeightDidChange = nil
    }

    private func resetReportingState() {
        deliveryTask?.cancel()
        deliveryTask = nil
        pendingHeight = nil
        lastReportedHeight = nil
    }

    private func reportAvailableHeightIfNeeded() {
        guard let window else { return }

        let windowFrame = window.bounds
        let sceneFrame = window.windowScene.map { scene in
            scene.coordinateSpace.convert(scene.coordinateSpace.bounds, to: window)
        } ?? windowFrame
        let presentationFrames = enclosingPresentationFrames(in: window)
        let contentFrame = convert(bounds, to: window).standardized
        guard let height = MobileAutoConnectMigrationViewportGeometry.availableHeight(
            sceneFrame: sceneFrame,
            windowFrame: windowFrame,
            containerFrame: presentationFrames?.container,
            presentedFrame: presentationFrames?.presented,
            contentOriginY: contentFrame.minY
        ),
        differsByVisiblePixel(
            height,
            from: pendingHeight ?? lastReportedHeight,
            in: window
        ) else {
            return
        }

        pendingHeight = height
        guard deliveryTask == nil else { return }
        deliveryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.deliveryTask = nil
            guard self.window != nil, let height = self.pendingHeight else { return }
            self.pendingHeight = nil
            self.lastReportedHeight = height
            self.availableHeightDidChange?(height)
        }
    }

    private func differsByVisiblePixel(
        _ height: CGFloat,
        from previousHeight: CGFloat?,
        in window: UIWindow
    ) -> Bool {
        guard let previousHeight else { return true }
        let displayScale = window.windowScene?.screen.scale
            ?? window.traitCollection.displayScale
        let pixel = 1 / max(displayScale, 1)
        return abs(height - previousHeight) >= pixel
    }

    /// The detent remains based on the intrinsic content measurement. Reading
    /// its UIKit presentation frame here therefore cannot feed the ScrollView's
    /// capped height back into the detent and oscillate.
    private func enclosingPresentationFrames(
        in window: UIWindow
    ) -> (container: CGRect, presented: CGRect)? {
        guard let presentationController = enclosingPresentationController(),
              let containerView = presentationController.containerView else {
            return nil
        }

        return (
            container: containerView.convert(containerView.bounds, to: window),
            presented: containerView.convert(
                presentationController.frameOfPresentedViewInContainerView,
                to: window
            )
        )
    }

    private func enclosingPresentationController() -> UIPresentationController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController,
               let presentationController = Self.presentationController(
                   startingAt: viewController
               ) {
                return presentationController
            }
            responder = nextResponder
        }
        return nil
    }

    private static func presentationController(
        startingAt viewController: UIViewController
    ) -> UIPresentationController? {
        var candidate: UIViewController? = viewController
        while let current = candidate {
            if let presentationController = current.presentationController,
               presentationController.presentedViewController === current {
                return presentationController
            }
            candidate = current.parent
        }
        return nil
    }
}
#endif
