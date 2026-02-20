import AppKit
import ObjectiveC

private var cmuxWindowTerminalPortalKey: UInt8 = 0
private var cmuxWindowTerminalPortalCloseObserverKey: UInt8 = 0

final class WindowTerminalHostView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === self ? nil : hitView
    }
}

@MainActor
final class WindowTerminalPortal: NSObject {
    private weak var window: NSWindow?
    private let hostView = WindowTerminalHostView(frame: .zero)
    private weak var installedContainerView: NSView?
    private weak var installedReferenceView: NSView?
    private var installConstraints: [NSLayoutConstraint] = []

    private struct Entry {
        weak var hostedView: GhosttySurfaceScrollView?
        weak var anchorView: NSView?
        var visibleInUI: Bool
        var zPriority: Int
    }

    private var entriesByHostedId: [ObjectIdentifier: Entry] = [:]
    private var hostedByAnchorId: [ObjectIdentifier: ObjectIdentifier] = [:]

    init(window: NSWindow) {
        self.window = window
        super.init()
        hostView.wantsLayer = false
        hostView.translatesAutoresizingMaskIntoConstraints = false
        _ = ensureInstalled()
    }

    @discardableResult
    private func ensureInstalled() -> Bool {
        guard let window else { return false }
        guard let (container, reference) = installationTarget(for: window) else { return false }

        if hostView.superview !== container ||
            installedContainerView !== container ||
            installedReferenceView !== reference {
            NSLayoutConstraint.deactivate(installConstraints)
            installConstraints.removeAll()

            hostView.removeFromSuperview()
            container.addSubview(hostView, positioned: .above, relativeTo: reference)

            installConstraints = [
                hostView.leadingAnchor.constraint(equalTo: reference.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: reference.trailingAnchor),
                hostView.topAnchor.constraint(equalTo: reference.topAnchor),
                hostView.bottomAnchor.constraint(equalTo: reference.bottomAnchor),
            ]
            NSLayoutConstraint.activate(installConstraints)
            installedContainerView = container
            installedReferenceView = reference
        } else if !Self.isView(hostView, above: reference, in: container) {
            container.addSubview(hostView, positioned: .above, relativeTo: reference)
        }

        // Keep the drag/mouse forwarding overlay above portal-hosted terminal views.
        if let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView,
           overlay.superview === container,
           !Self.isView(overlay, above: hostView, in: container) {
            container.addSubview(overlay, positioned: .above, relativeTo: hostView)
        }

        return true
    }

    private func installationTarget(for window: NSWindow) -> (container: NSView, reference: NSView)? {
        guard let contentView = window.contentView else { return nil }

        // If NSGlassEffectView wraps the original content view, install inside the glass view
        // so terminals are above the glass background but below SwiftUI content.
        if contentView.className == "NSGlassEffectView",
           let foreground = contentView.subviews.first(where: { $0 !== hostView }) {
            return (contentView, foreground)
        }

        guard let themeFrame = contentView.superview else { return nil }
        return (themeFrame, contentView)
    }

    private static func isHiddenOrAncestorHidden(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        var current = view.superview
        while let v = current {
            if v.isHidden { return true }
            current = v.superview
        }
        return false
    }

    private static func rectApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    private static func isView(_ view: NSView, above reference: NSView, in container: NSView) -> Bool {
        guard let viewIndex = container.subviews.firstIndex(of: view),
              let referenceIndex = container.subviews.firstIndex(of: reference) else {
            return false
        }
        return viewIndex > referenceIndex
    }

    func detachHostedView(withId hostedId: ObjectIdentifier) {
        guard let entry = entriesByHostedId.removeValue(forKey: hostedId) else { return }
        if let anchor = entry.anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(anchor))
        }
        if let hostedView = entry.hostedView, hostedView.superview === hostView {
            hostedView.removeFromSuperview()
        }
    }

    func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard ensureInstalled() else { return }

        let hostedId = ObjectIdentifier(hostedView)
        let anchorId = ObjectIdentifier(anchorView)
        let previousEntry = entriesByHostedId[hostedId]

        if let previousHostedId = hostedByAnchorId[anchorId], previousHostedId != hostedId {
            detachHostedView(withId: previousHostedId)
        }

        if let oldEntry = entriesByHostedId[hostedId],
           let oldAnchor = oldEntry.anchorView,
           oldAnchor !== anchorView {
            hostedByAnchorId.removeValue(forKey: ObjectIdentifier(oldAnchor))
        }

        hostedByAnchorId[anchorId] = hostedId
        entriesByHostedId[hostedId] = Entry(
            hostedView: hostedView,
            anchorView: anchorView,
            visibleInUI: visibleInUI,
            zPriority: zPriority
        )

        let didChangeAnchor: Bool = {
            guard let previousAnchor = previousEntry?.anchorView else { return true }
            return previousAnchor !== anchorView
        }()
        let becameVisible = (previousEntry?.visibleInUI ?? false) == false && visibleInUI
        let priorityIncreased = zPriority > (previousEntry?.zPriority ?? Int.min)

        if hostedView.superview !== hostView {
            hostedView.removeFromSuperview()
            hostView.addSubview(hostedView)
        } else if (didChangeAnchor || becameVisible || priorityIncreased), hostView.subviews.last !== hostedView {
            // Refresh z-order only on meaningful transitions. Reordering on every bind call
            // creates expensive reparent loops during SwiftUI update/layout churn.
            hostedView.removeFromSuperview()
            hostView.addSubview(hostedView)
        }

        synchronizeHostedView(withId: hostedId)
        pruneDeadEntries()
    }

    func synchronizeHostedViewForAnchor(_ anchorView: NSView) {
        pruneDeadEntries()
        guard let hostedId = hostedByAnchorId[ObjectIdentifier(anchorView)] else { return }
        synchronizeHostedView(withId: hostedId)
    }

    private func synchronizeHostedView(withId hostedId: ObjectIdentifier) {
        guard ensureInstalled() else { return }
        guard let entry = entriesByHostedId[hostedId] else { return }
        guard let hostedView = entry.hostedView else {
            entriesByHostedId.removeValue(forKey: hostedId)
            return
        }
        guard let anchorView = entry.anchorView, let window else {
            hostedView.isHidden = true
            return
        }
        guard anchorView.window === window else {
            hostedView.isHidden = true
            return
        }

        let frameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let frameInHost = hostView.convert(frameInWindow, from: nil)
        let anchorTooSmall = frameInHost.width <= 1 || frameInHost.height <= 1

        // When the anchor exists and is marked visible but hasn't been laid out yet
        // (zero/tiny bounds), keep the terminal visible at its current frame. Hiding
        // it would cause a single-frame black flash during drag-to-swap and other
        // reparenting operations. The next layout pass will call us again with real
        // bounds and we'll reposition then.
        if anchorTooSmall && entry.visibleInUI && !Self.isHiddenOrAncestorHidden(anchorView) {
            if hostedView.isHidden {
                hostedView.isHidden = false
            }
            return
        }

        let shouldHide =
            !entry.visibleInUI ||
            Self.isHiddenOrAncestorHidden(anchorView)

        let oldFrame = hostedView.frame
        if !Self.rectApproximatelyEqual(oldFrame, frameInHost) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedView.frame = frameInHost
            CATransaction.commit()

            if abs(oldFrame.size.width - frameInHost.size.width) > 0.5 ||
                abs(oldFrame.size.height - frameInHost.size.height) > 0.5 {
                hostedView.reconcileGeometryNow()
            }
        }

        if hostedView.isHidden != shouldHide {
            hostedView.isHidden = shouldHide
        }
    }

    private func pruneDeadEntries() {
        let currentWindow = window
        let deadHostedIds = entriesByHostedId.compactMap { hostedId, entry -> ObjectIdentifier? in
            guard entry.hostedView != nil else { return hostedId }
            guard let anchor = entry.anchorView else { return hostedId }
            if anchor.window !== currentWindow || anchor.superview == nil {
                return hostedId
            }
            return nil
        }

        for hostedId in deadHostedIds {
            detachHostedView(withId: hostedId)
        }

        let validAnchorIds = Set(entriesByHostedId.compactMap { _, entry in
            entry.anchorView.map { ObjectIdentifier($0) }
        })
        hostedByAnchorId = hostedByAnchorId.filter { validAnchorIds.contains($0.key) }
    }

    func hostedIds() -> Set<ObjectIdentifier> {
        Set(entriesByHostedId.keys)
    }

    func tearDown() {
        for hostedId in Array(entriesByHostedId.keys) {
            detachHostedView(withId: hostedId)
        }
        NSLayoutConstraint.deactivate(installConstraints)
        installConstraints.removeAll()
        hostView.removeFromSuperview()
        installedContainerView = nil
        installedReferenceView = nil
    }

#if DEBUG
    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
#endif

    func viewAtWindowPoint(_ windowPoint: NSPoint) -> NSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        // Restrict hit-testing to currently mapped entries so stale detached views
        // can't steal file-drop/mouse routing.
        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            return hostedView.hitTest(localPoint) ?? hostedView
        }

        return nil
    }

    func terminalViewAtWindowPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView else { continue }
            let hostedId = ObjectIdentifier(hostedView)
            guard entriesByHostedId[hostedId] != nil else { continue }
            guard !hostedView.isHidden else { continue }
            guard hostedView.frame.contains(point) else { continue }
            let localPoint = hostedView.convert(point, from: hostView)
            if let terminal = hostedView.terminalViewForDrop(at: localPoint) {
                return terminal
            }
        }

        return nil
    }
}

@MainActor
enum TerminalWindowPortalRegistry {
    private static var portalsByWindowId: [ObjectIdentifier: WindowTerminalPortal] = [:]
    private static var hostedToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &cmuxWindowTerminalPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        hostedToWindowId = hostedToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneHostedMappings(for windowId: ObjectIdentifier, validHostedIds: Set<ObjectIdentifier>) {
        hostedToWindowId = hostedToWindowId.filter { hostedId, mappedWindowId in
            mappedWindowId != windowId || validHostedIds.contains(hostedId)
        }
    }

    private static func portal(for window: NSWindow) -> WindowTerminalPortal {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowTerminalPortalKey) as? WindowTerminalPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowTerminalPortal(window: window)
        objc_setAssociatedObject(window, &cmuxWindowTerminalPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    static func bind(hostedView: GhosttySurfaceScrollView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let hostedId = ObjectIdentifier(hostedView)
        let nextPortal = portal(for: window)

        if let oldWindowId = hostedToWindowId[hostedId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachHostedView(withId: hostedId)
        }

        nextPortal.bind(hostedView: hostedView, to: anchorView, visibleInUI: visibleInUI, zPriority: zPriority)
        hostedToWindowId[hostedId] = windowId
        pruneHostedMappings(for: windowId, validHostedIds: nextPortal.hostedIds())
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window)
        portal.synchronizeHostedViewForAnchor(anchorView)
    }

    static func viewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> NSView? {
        let portal = portal(for: window)
        return portal.viewAtWindowPoint(windowPoint)
    }

    static func terminalViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> GhosttyNSView? {
        let portal = portal(for: window)
        return portal.terminalViewAtWindowPoint(windowPoint)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }
#endif
}
