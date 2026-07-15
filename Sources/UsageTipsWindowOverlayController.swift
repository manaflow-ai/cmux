import AppKit
import CmuxFoundation
import ObjectiveC
import SwiftUI

private let usageTipsOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.usageTips.overlay.container")

@MainActor
final class UsageTipsWindowOverlayController: NSObject {
    private static var associationKey: UInt8 = 0
    private static let cardPadding: CGFloat = 18
    private static let fadeDuration: TimeInterval = 0.24

    private weak var window: NSWindow?
    private weak var usageTipsController: UsageTipsController?
    private let windowID: UUID
    private let containerView = UsageTipsOverlayContainerView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var requestedPresentation: UsageTipPresentation?
    private var displayedPresentation: UsageTipPresentation?
    private var animationGeneration: UInt = 0

    static func attach(
        to window: NSWindow,
        controller: UsageTipsController,
        windowID: UUID
    ) -> UsageTipsWindowOverlayController {
        if let existing = self.controller(for: window) {
            return existing
        }
        let overlayController = UsageTipsWindowOverlayController(
            window: window,
            controller: controller,
            windowID: windowID
        )
        objc_setAssociatedObject(
            window,
            &Self.associationKey,
            overlayController,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        overlayController.attachToWindowLifecycle()
        return overlayController
    }

    static func controller(for window: NSWindow) -> UsageTipsWindowOverlayController? {
        objc_getAssociatedObject(window, &Self.associationKey) as? UsageTipsWindowOverlayController
    }

    private init(window: NSWindow, controller: UsageTipsController, windowID: UUID) {
        self.window = window
        self.usageTipsController = controller
        self.windowID = windowID
        super.init()
        configureViews()
        installWindowObservers(window: window)
        _ = ensureInstalled()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(presentation: UsageTipPresentation?) {
        requestedPresentation = presentation?.windowID == windowID ? presentation : nil
        reconcilePresentation()
    }

    func refreshInstallation() {
        reconcilePresentation()
    }

    private func configureViews() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.clipsToBounds = false
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.masksToBounds = false
        containerView.isHidden = true
        containerView.alphaValue = 0
        containerView.identifier = usageTipsOverlayContainerIdentifier

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.clipsToBounds = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.masksToBounds = false
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        hostingView.setContentHuggingPriority(.required, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hostingView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        containerView.interactiveView = hostingView
        containerView.interactiveContentInsets = NSEdgeInsets(
            top: Self.cardPadding,
            left: Self.cardPadding,
            bottom: Self.cardPadding,
            right: Self.cardPadding
        )
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor),
            hostingView.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    private func installWindowObservers(window: NSWindow) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func attachToWindowLifecycle() {
        guard let window, let usageTipsController else { return }
        usageTipsController.register(windowID: windowID)
        if window.isKeyWindow {
            usageTipsController.windowDidBecomeKey(windowID: windowID)
        }
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        usageTipsController?.windowDidBecomeKey(windowID: windowID)
        refreshInstallation()
    }

    @objc
    private func windowDidResignKey(_ notification: Notification) {
        usageTipsController?.windowDidResignKey(windowID: windowID)
    }

    @objc
    private func windowWillClose(_ notification: Notification) {
        usageTipsController?.unregister(windowID: windowID)
        hideImmediately()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window,
              let target = chromeComposition
                .contentOverlayTargetResolver
                .installationTarget(for: window) else { return false }

        if containerView.superview !== target.container || installedReferenceView !== target.reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()
            containerView.removeFromSuperview()
            target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
            installConstraints = [
                containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
                containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
                containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
                containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = target.container
            installedReferenceView = target.reference
        }
        return true
    }

    private func promoteAbovePortalSiblings() {
        guard let installedContainerView,
              containerView.superview === installedContainerView else { return }
        installedContainerView.addSubview(containerView, positioned: .above, relativeTo: nil)
    }

    private func reconcilePresentation() {
        guard ensureInstalled() else { return }
        if !containerView.isHidden {
            promoteAbovePortalSiblings()
        }
        guard requestedPresentation != displayedPresentation else { return }
        if let presentation = requestedPresentation {
            show(presentation: presentation)
        } else {
            hide()
        }
    }

    private func show(presentation: UsageTipPresentation) {
        let wasHidden = containerView.isHidden
        displayedPresentation = presentation
        animationGeneration &+= 1
        containerView.layer?.removeAllAnimations()
        hostingView.rootView = cardView(for: presentation)
        hostingView.invalidateIntrinsicContentSize()
        containerView.layoutSubtreeIfNeeded()
        containerView.isHidden = false
        promoteAbovePortalSiblings()

        guard wasHidden else {
            containerView.alphaValue = 1
            return
        }
        containerView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            containerView.animator().alphaValue = 1
        }
    }

    private func hide() {
        displayedPresentation = nil
        guard !containerView.isHidden else {
            hostingView.rootView = AnyView(EmptyView())
            return
        }
        animationGeneration &+= 1
        let generation = animationGeneration
        containerView.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            containerView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.containerView.isHidden = true
                self.hostingView.rootView = AnyView(EmptyView())
                self.hostingView.invalidateIntrinsicContentSize()
            }
        }
    }

    private func hideImmediately() {
        requestedPresentation = nil
        displayedPresentation = nil
        animationGeneration &+= 1
        containerView.layer?.removeAllAnimations()
        containerView.alphaValue = 0
        containerView.isHidden = true
        hostingView.rootView = AnyView(EmptyView())
    }

    private func cardView(for presentation: UsageTipPresentation) -> AnyView {
        return AnyView(
            UsageTipCard(
                presentation: presentation,
                onAcknowledge: { [weak self] in self?.usageTipsController?.acknowledge() }
            )
            // Usage tips are passive chrome: terminal keyboard focus must never enter this overlay.
            .focusable(false)
            .padding(Self.cardPadding)
            .cmuxFontMagnificationEnvironment()
        )
    }
}
