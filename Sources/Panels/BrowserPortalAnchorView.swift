import AppKit

final class BrowserPortalAnchorView: NSView {
    private var installationConstraints: [NSLayoutConstraint] = []
    private var hasSynchronizedPortalGeometry = false
    private var lastSynchronizedFrame = NSRect.zero
    private var lastSynchronizedBounds = NSRect.zero
    private var lastSynchronizedWindowID: ObjectIdentifier?
    private var lastSynchronizedSuperviewID: ObjectIdentifier?
    private var isSynchronizingPortalGeometry = false

    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }

    /// Reparents and pins this anchor to an on-window browser host.
    func install(in host: NSView) {
        // SwiftUI can keep transient replacement hosts alive off-window during split
        // reparenting. Never let those hosts steal the shared portal anchor, or the
        // portal will bind against an anchor with no real window and WKWebView will
        // fall into a hidden/unrendered state.
        guard host.window != nil else { return }

        let needsReparent = superview !== host
        let needsConstraints =
            needsReparent ||
            translatesAutoresizingMaskIntoConstraints ||
            installationConstraints.isEmpty ||
            installationConstraints.contains(where: { !$0.isActive })
        guard needsConstraints else { return }

        NSLayoutConstraint.deactivate(installationConstraints)
        installationConstraints.removeAll(keepingCapacity: true)
        if needsReparent {
            removeFromSuperview()
            translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(self)
        } else if translatesAutoresizingMaskIntoConstraints {
            translatesAutoresizingMaskIntoConstraints = false
        }

        installationConstraints = [
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ]
        NSLayoutConstraint.activate(installationConstraints)
        host.needsLayout = true
        markPortalGeometrySynchronizationNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        markPortalGeometrySynchronizationNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        markPortalGeometrySynchronizationNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil, !installationConstraints.isEmpty {
            NSLayoutConstraint.deactivate(installationConstraints)
            installationConstraints.removeAll(keepingCapacity: true)
        }
        markPortalGeometrySynchronizationNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        markPortalGeometrySynchronizationNeeded()
    }

    override func layout() {
        super.layout()
        synchronizePortalGeometryIfNeeded()
    }

    private var portalGeometryRequiresSynchronization: Bool {
        !hasSynchronizedPortalGeometry ||
            frame != lastSynchronizedFrame ||
            bounds != lastSynchronizedBounds ||
            window.map(ObjectIdentifier.init) != lastSynchronizedWindowID ||
            superview.map(ObjectIdentifier.init) != lastSynchronizedSuperviewID
    }

    private func markPortalGeometrySynchronizationNeeded() {
        guard portalGeometryRequiresSynchronization else { return }
        needsLayout = true
    }

    private func synchronizePortalGeometryIfNeeded() {
        guard !isSynchronizingPortalGeometry,
              window != nil,
              superview != nil else { return }
        guard portalGeometryRequiresSynchronization else { return }

        isSynchronizingPortalGeometry = true
        defer { isSynchronizingPortalGeometry = false }
        guard BrowserWindowPortalRegistry.synchronizeIfBoundForAnchor(self) else { return }
        hasSynchronizedPortalGeometry = true
        lastSynchronizedFrame = frame
        lastSynchronizedBounds = bounds
        lastSynchronizedWindowID = window.map(ObjectIdentifier.init)
        lastSynchronizedSuperviewID = superview.map(ObjectIdentifier.init)
    }
}
