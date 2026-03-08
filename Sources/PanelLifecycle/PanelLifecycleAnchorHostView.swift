import AppKit

enum PanelLifecycleCurrentAnchorMountPolicy {
    static func shouldMountLiveAnchor(panelType: PanelType, isVisibleInUI: Bool) -> Bool {
        switch panelType {
        case .terminal, .browser:
            return isVisibleInUI
        case .markdown:
            return false
        }
    }
}

class PanelLifecycleAnchorHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    let panelLifecycleAnchorId = UUID()
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedGeometryState: GeometryState?

    private struct GeometryState: Equatable {
        let frame: CGRect
        let bounds: CGRect
        let windowNumber: Int?
        let superviewID: ObjectIdentifier?
    }

    func panelLifecycleViewDidMoveToWindow() {}
    func panelLifecycleViewDidMoveToSuperview() {}
    func panelLifecycleViewDidLayout() {}
    func panelLifecycleViewDidSetFrameOrigin() {}
    func panelLifecycleViewDidSetFrameSize() {}

    private func currentGeometryState() -> GeometryState {
        GeometryState(
            frame: frame,
            bounds: bounds,
            windowNumber: window?.windowNumber,
            superviewID: superview.map(ObjectIdentifier.init)
        )
    }

    private func notifyGeometryChangedIfNeeded() {
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        lastReportedGeometryState = state
        geometryRevision &+= 1
        onGeometryChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        panelLifecycleViewDidMoveToWindow()
        onDidMoveToWindow?()
        notifyGeometryChangedIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        panelLifecycleViewDidMoveToSuperview()
        notifyGeometryChangedIfNeeded()
    }

    override func layout() {
        super.layout()
        panelLifecycleViewDidLayout()
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        panelLifecycleViewDidSetFrameOrigin()
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        panelLifecycleViewDidSetFrameSize()
        notifyGeometryChangedIfNeeded()
    }
}
