import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


private final class BrowserDropZoneOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct BrowserPortalOmnibarSuggestionsOverlay: View {
    let configuration: BrowserPortalOmnibarSuggestionsConfiguration

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                OmnibarSuggestionsView(
                    engineName: configuration.engineName,
                    items: configuration.items,
                    selectedIndex: configuration.selectedIndex,
                    isLoadingRemoteSuggestions: configuration.isLoadingRemoteSuggestions,
                    searchSuggestionsEnabled: configuration.searchSuggestionsEnabled,
                    onCommit: configuration.onCommit,
                    onHighlight: configuration.onHighlight
                )
                .frame(width: configuration.popupFrame.width)
                .offset(x: configuration.popupFrame.minX, y: configuration.popupFrame.minY)
                .environment(\.colorScheme, configuration.colorScheme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private final class BrowserPortalOmnibarSuggestionsHostingView: NSHostingView<BrowserPortalOmnibarSuggestionsOverlay> {
    var popupFrameInTopLeftCoordinates: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let topLeftPoint: NSPoint
        if isFlipped {
            topLeftPoint = point
        } else {
            topLeftPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        }
        guard popupFrameInTopLeftCoordinates.contains(topLeftPoint) else { return nil }
        return super.hitTest(point)
    }
}

final class WindowBrowserSlotView: NSView {
    override var isOpaque: Bool { false }
    override var isHidden: Bool {
        didSet {
            guard isHidden, !oldValue, let window else { return }
            yieldOwnedFirstResponderIfNeeded(in: window, reason: "slotHidden")
        }
    }
    private let paneDropTargetView = BrowserPaneDropTargetView(frame: .zero)
    private let dropZoneOverlayView = BrowserDropZoneOverlayView(frame: .zero)
    private var searchOverlayHostingView: NSHostingView<BrowserSearchOverlay>?
    private var omnibarSuggestionsHostingView: BrowserPortalOmnibarSuggestionsHostingView?
    private weak var hostedWebView: WKWebView?
    private var hostedWebViewConstraints: [NSLayoutConstraint] = []
    private var forwardedDropZone: DropZone?
    private var portalDragDropZone: DropZone?
    private var displayedDropZone: DropZone?
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    private var isRefreshingInteractionLayers = false
    private var paneTopChromeHeight: CGFloat = 0
    var preferredHostedInspectorWidth: CGFloat?
    private var preferredHostedInspectorWidthFraction: CGFloat?
    var isHostedInspectorDividerDragActive = false
    var onHostedInspectorLayout: ((WindowBrowserSlotView) -> Void)?
    var isApplyingHostedInspectorLayout = false
    private var lastHostedInspectorLayoutBoundsSize: NSSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []

        paneDropTargetView.slotView = self

        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = cmuxAccentNSColor().cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let currentWindow = window {
            yieldOwnedFirstResponderIfNeeded(in: currentWindow, reason: "slotWillLeaveWindow")
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        paneDropTargetView.frame = bounds
        applyResolvedDropZoneOverlay()
        guard !isApplyingHostedInspectorLayout else { return }
        if let previousSize = lastHostedInspectorLayoutBoundsSize,
           Self.sizeApproximatelyEqual(previousSize, bounds.size) {
            return
        }
        lastHostedInspectorLayoutBoundsSize = bounds.size
        onHostedInspectorLayout?(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachDropZoneOverlayIfNeeded()
        applyResolvedDropZoneOverlay()
    }

    func recordPreferredHostedInspectorWidth(_ width: CGFloat, containerBounds: NSRect) {
        preferredHostedInspectorWidth = width
        guard containerBounds.width > 0 else {
            preferredHostedInspectorWidthFraction = nil
            return
        }
        preferredHostedInspectorWidthFraction = width / containerBounds.width
    }

    func resolvedPreferredHostedInspectorWidth(in containerBounds: NSRect) -> CGFloat? {
        if let preferredHostedInspectorWidthFraction, containerBounds.width > 0 {
            return max(0, containerBounds.width * preferredHostedInspectorWidthFraction)
        }
        return preferredHostedInspectorWidth
    }

    private static func sizeApproximatelyEqual(_ lhs: NSSize, _ rhs: NSSize, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        forwardedDropZone = zone
        applyResolvedDropZoneOverlay()
    }

    func setPortalDragDropZone(_ zone: DropZone?) {
        portalDragDropZone = zone
        applyResolvedDropZoneOverlay()
    }

    func setPaneDropContext(_ context: BrowserPaneDropContext?) {
        paneDropTargetView.dropContext = context
    }

    func paneDropTargetForDrop(at localPoint: NSPoint) -> BrowserPaneDropTargetView? {
        guard paneDropTargetView.dropContext != nil else { return nil }
        guard bounds.contains(localPoint) else { return nil }
        let pointInTarget = paneDropTargetView.convert(localPoint, from: self)
        guard paneDropTargetView.bounds.contains(pointInTarget) else { return nil }
        guard !paneDropTargetView.shouldDeferToPaneTabBar(at: pointInTarget) else { return nil }
        return paneDropTargetView
    }

    func hostedWebViewForFileDrop(at localPoint: NSPoint) -> WKWebView? {
        guard let hostedWebView else { return nil }
        let webPoint = hostedWebView.convert(localPoint, from: self)
        guard hostedWebView.bounds.contains(webPoint) else { return nil }
        return hostedWebView
    }

    func setPaneTopChromeHeight(_ height: CGFloat) {
        let resolvedHeight = max(0, height)
        guard abs(paneTopChromeHeight - resolvedHeight) > 0.5 else { return }
        paneTopChromeHeight = resolvedHeight
        applyResolvedDropZoneOverlay()
    }

    private func logSearchOverlayEvent(_ action: String, panelId: UUID?) {
#if DEBUG
        let firstResponderSummary: String = {
            guard let firstResponder = window?.firstResponder else { return "nil" }
            if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
                let delegateSummary = editor.delegate.map { String(describing: type(of: $0)) } ?? "nil"
                return "fieldEditor(delegate=\(delegateSummary))"
            }
            return String(describing: type(of: firstResponder))
        }()
        cmuxDebugLog(
            "browser.findbar.portal action=\(action) " +
            "panel=\(panelId?.uuidString.prefix(5) ?? "nil") " +
            "window=\(window?.windowNumber ?? -1) " +
            "firstResponder=\(firstResponderSummary) " +
            "hasOverlay=\(searchOverlayHostingView != nil ? 1 : 0)"
        )
#endif
    }

    func setSearchOverlay(_ configuration: BrowserPortalSearchOverlayConfiguration?) {
        guard let configuration else {
            logSearchOverlayEvent("remove", panelId: nil)
            if let overlay = searchOverlayHostingView {
                objc_setAssociatedObject(
                    overlay,
                    &cmuxBrowserSearchOverlayPanelIdAssociationKey,
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
            searchOverlayHostingView?.removeFromSuperview()
            searchOverlayHostingView = nil
            return
        }

        logSearchOverlayEvent("set", panelId: configuration.panelId)
        let rootView = BrowserSearchOverlay(
            panelId: configuration.panelId,
            searchState: configuration.searchState,
            focusRequestGeneration: configuration.focusRequestGeneration,
            canApplyFocusRequest: configuration.canApplyFocusRequest,
            onNext: configuration.onNext,
            onPrevious: configuration.onPrevious,
            onClose: configuration.onClose,
            onFieldDidFocus: configuration.onFieldDidFocus
        )

        if let overlay = searchOverlayHostingView {
            logSearchOverlayEvent("updateExisting", panelId: configuration.panelId)
            overlay.rootView = rootView
            objc_setAssociatedObject(
                overlay,
                &cmuxBrowserSearchOverlayPanelIdAssociationKey,
                configuration.panelId,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            if overlay.superview !== self {
                overlay.removeFromSuperview()
                addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                    overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            bringInteractionLayersToFrontIfNeeded()
            return
        }

        let overlay = NSHostingView(rootView: rootView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(
            overlay,
            &cmuxBrowserSearchOverlayPanelIdAssociationKey,
            configuration.panelId,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        searchOverlayHostingView = overlay
        logSearchOverlayEvent("create", panelId: configuration.panelId)
        bringInteractionLayersToFrontIfNeeded()
    }

    private func logOmnibarSuggestionsEvent(_ action: String, configuration: BrowserPortalOmnibarSuggestionsConfiguration?) {
#if DEBUG
        cmuxDebugLog(
            "browser.omnibar.portal action=\(action) " +
            "panel=\(configuration?.panelId.uuidString.prefix(5) ?? "nil") " +
            "window=\(window?.windowNumber ?? -1) " +
            "items=\(configuration?.items.count ?? 0) " +
            "frame=\(browserPortalDebugFrame(configuration?.popupFrame ?? .zero)) " +
            "hasOverlay=\(omnibarSuggestionsHostingView != nil ? 1 : 0)"
        )
#endif
    }

    func setOmnibarSuggestions(_ configuration: BrowserPortalOmnibarSuggestionsConfiguration?) {
        guard let configuration else {
            logOmnibarSuggestionsEvent("remove", configuration: nil)
            omnibarSuggestionsHostingView?.removeFromSuperview()
            omnibarSuggestionsHostingView = nil
            return
        }

        logOmnibarSuggestionsEvent("set", configuration: configuration)
        let rootView = BrowserPortalOmnibarSuggestionsOverlay(configuration: configuration)

        if let overlay = omnibarSuggestionsHostingView {
            logOmnibarSuggestionsEvent("updateExisting", configuration: configuration)
            overlay.rootView = rootView
            overlay.popupFrameInTopLeftCoordinates = configuration.popupFrame
            if overlay.superview !== self {
                overlay.removeFromSuperview()
                addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                    overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            bringInteractionLayersToFrontIfNeeded()
            return
        }

        let overlay = BrowserPortalOmnibarSuggestionsHostingView(rootView: rootView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.popupFrameInTopLeftCoordinates = configuration.popupFrame
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        omnibarSuggestionsHostingView = overlay
        logOmnibarSuggestionsEvent("create", configuration: configuration)
        bringInteractionLayersToFrontIfNeeded()
    }

    private func searchOverlayOwnsFieldEditor(_ fieldEditor: NSTextView, in root: NSView) -> Bool {
        guard fieldEditor.isFieldEditor else { return false }

        if let textField = root as? NSTextField, textField.currentEditor() === fieldEditor {
            return true
        }

        for subview in root.subviews {
            if searchOverlayOwnsFieldEditor(fieldEditor, in: subview) {
                return true
            }
        }

        return false
    }

    func searchOverlayPanelId(for responder: NSResponder) -> UUID? {
        guard let overlay = searchOverlayHostingView else { return nil }

        let panelId = objc_getAssociatedObject(overlay, &cmuxBrowserSearchOverlayPanelIdAssociationKey) as? UUID

        if let view = responder as? NSView,
           view === overlay || view.isDescendant(of: overlay) {
            return panelId
        }

        if let fieldEditor = responder as? NSTextView,
           searchOverlayOwnsFieldEditor(fieldEditor, in: overlay) {
            return panelId
        }

        return nil
    }

    @discardableResult
    func yieldSearchOverlayFocusIfOwned(by panelId: UUID, in window: NSWindow) -> Bool {
        guard let firstResponder = window.firstResponder,
              searchOverlayPanelId(for: firstResponder) == panelId else {
            return false
        }
        _ = cmuxRememberFindSelection(in: searchOverlayHostingView); return window.makeFirstResponder(nil)
    }

    @discardableResult
    private func yieldOwnedFirstResponderIfNeeded(in window: NSWindow, reason: String) -> Bool {
        guard let firstResponder = window.firstResponder,
              let owningView = firstResponder.browserPortalOwningView,
              owningView === self || owningView.isDescendant(of: self) else {
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "browser.slot.firstResponder.yield reason=\(reason) " +
            "slot=\(browserPortalDebugToken(self)) " +
            "responder=\(String(describing: type(of: firstResponder)))"
        )
#endif
        return window.makeFirstResponder(nil)
    }

    func pinHostedWebView(_ webView: WKWebView) {
        guard webView.superview === self else { return }

        let hasCompanionWKSubviews = Self.hasWebKitCompanionSubview(in: self, primaryWebView: webView)
        let needsPlainWebViewFrameReset =
            !hasCompanionWKSubviews &&
            Self.frameDiffersFromBounds(webView.frame, bounds: bounds)
        let needsFrameHosting =
            hostedWebView !== webView ||
            !hostedWebViewConstraints.isEmpty ||
            needsPlainWebViewFrameReset ||
            !webView.translatesAutoresizingMaskIntoConstraints ||
            webView.autoresizingMask != [.width, .height]
        guard needsFrameHosting else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }

        NSLayoutConstraint.deactivate(hostedWebViewConstraints)
        hostedWebViewConstraints = []
        hostedWebView = webView
        // Attached Web Inspector mutates the moved WKWebView's frame directly.
        // Re-pin plain web views after cross-host reattach, but preserve the
        // WebKit-managed split frame when docked DevTools siblings are present.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        if !hasCompanionWKSubviews {
            webView.frame = bounds
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private static func frameDiffersFromBounds(_ frame: NSRect, bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(frame.minX - bounds.minX) > epsilon ||
            abs(frame.minY - bounds.minY) > epsilon ||
            abs(frame.width - bounds.width) > epsilon ||
            abs(frame.height - bounds.height) > epsilon
    }

    private static func hasWebKitCompanionSubview(in host: NSView, primaryWebView: WKWebView) -> Bool {
        var stack = host.subviews.filter { $0 !== primaryWebView }
        while let current = stack.popLast() {
            if current.isDescendant(of: primaryWebView) {
                continue
            }
            if current.isHidden || current.alphaValue <= 0 {
                continue
            }
            if String(describing: type(of: current)).contains("WK") {
                let width = max(current.frame.width, current.bounds.width)
                let height = max(current.frame.height, current.bounds.height)
                if width > 1, height > 1 {
                    return true
                }
                continue
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }

    func effectivePaneTopChromeHeight() -> CGFloat {
        paneTopChromeHeight
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== paneDropTargetView else { return }
        bringInteractionLayersToFrontIfNeeded()
    }

    private var activeDropZone: DropZone? {
        portalDragDropZone ?? forwardedDropZone
    }

    private func overlayContainerView() -> NSView {
        superview ?? self
    }

    private func attachDropZoneOverlayIfNeeded() {
        let container = overlayContainerView()
        guard dropZoneOverlayView.superview !== container else { return }
        dropZoneOverlayView.removeFromSuperview()
        container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
    }

    private func applyResolvedDropZoneOverlay() {
        let resolvedZone = activeDropZone
        if resolvedZone != nil, (bounds.width <= 2 || bounds.height <= 2) {
            bringInteractionLayersToFrontIfNeeded()
            return
        }

        let previousZone = displayedDropZone
        displayedDropZone = resolvedZone
        let previousFrame = dropZoneOverlayView.frame

        guard let zone = resolvedZone else {
            guard !dropZoneOverlayView.isHidden else {
                bringInteractionLayersToFrontIfNeeded()
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
            bringInteractionLayersToFrontIfNeeded()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.displayedDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
            }
            return
        }
        attachDropZoneOverlayIfNeeded()

        let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
        let needsFrameUpdate = !Self.rectApproximatelyEqual(previousFrame, targetFrame)
        let zoneChanged = previousZone != zone

        if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
            bringInteractionLayersToFrontIfNeeded()
            return
        }

        dropZoneOverlayAnimationGeneration &+= 1
        dropZoneOverlayView.layer?.removeAllAnimations()

        if dropZoneOverlayView.isHidden {
            applyDropZoneOverlayFrame(targetFrame)
            dropZoneOverlayView.alphaValue = 0
            dropZoneOverlayView.isHidden = false
            bringInteractionLayersToFrontIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dropZoneOverlayView.animator().alphaValue = 1
            }
            return
        }

        bringInteractionLayersToFrontIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if needsFrameUpdate {
                dropZoneOverlayView.animator().frame = targetFrame
            }
            if dropZoneOverlayView.alphaValue < 1 {
                dropZoneOverlayView.animator().alphaValue = 1
            }
        }
    }

    private func interactionLayerPriority(of view: NSView) -> Int {
        if view === paneDropTargetView { return 3 }
        if view === omnibarSuggestionsHostingView { return 2 }
        if view === searchOverlayHostingView { return 1 }
        return 0
    }

    private func bringInteractionLayersToFrontIfNeeded() {
        guard !isRefreshingInteractionLayers else { return }
        isRefreshingInteractionLayers = true
        defer { isRefreshingInteractionLayers = false }

        if paneDropTargetView.superview !== self {
            addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        }
        let overlayContainer = overlayContainerView()
        if dropZoneOverlayView.superview !== overlayContainer {
            attachDropZoneOverlayIfNeeded()
        } else if overlayContainer.subviews.last !== dropZoneOverlayView {
            overlayContainer.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        sortSubviews({ lhs, rhs, context in
            guard let context else { return .orderedSame }
            let slotView = Unmanaged<WindowBrowserSlotView>.fromOpaque(context).takeUnretainedValue()
            let lhsPriority = slotView.interactionLayerPriority(of: lhs)
            let rhsPriority = slotView.interactionLayerPriority(of: rhs)
            if lhsPriority == rhsPriority { return .orderedSame }
            return lhsPriority < rhsPriority ? .orderedAscending : .orderedDescending
        }, context: context)
    }

    private func applyDropZoneOverlayFrame(_ frame: CGRect) {
        if Self.rectApproximatelyEqual(dropZoneOverlayView.frame, frame) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropZoneOverlayView.frame = frame
        CATransaction.commit()
    }

    private func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let localFrame = BrowserPaneDropRouting.overlayFrame(
            for: zone,
            in: size,
            topChromeHeight: paneTopChromeHeight
        )
        guard let superview else { return localFrame }
        return superview.convert(localFrame, from: self)
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }
}

