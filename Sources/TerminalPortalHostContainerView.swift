import AppKit

final class TerminalPortalHostContainerView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedFrame: CGRect?
    private var lastReportedBounds: CGRect?
    private var lastReportedWindowNumber: Int?
    private var lastReportedSuperviewID: ObjectIdentifier?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private func notifyGeometryChangedIfNeeded() {
        let windowNumber = window?.windowNumber
        let superviewID = superview.map(ObjectIdentifier.init)
        guard frame != lastReportedFrame ||
                bounds != lastReportedBounds ||
                windowNumber != lastReportedWindowNumber ||
                superviewID != lastReportedSuperviewID else { return }
        lastReportedFrame = frame
        lastReportedBounds = bounds
        lastReportedWindowNumber = windowNumber
        lastReportedSuperviewID = superviewID
        geometryRevision &+= 1
        onGeometryChanged?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
        notifyGeometryChangedIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notifyGeometryChangedIfNeeded()
    }

    override func layout() {
        super.layout()
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        notifyGeometryChangedIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyGeometryChangedIfNeeded()
    }
}
