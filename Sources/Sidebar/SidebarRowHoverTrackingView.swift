import AppKit

@MainActor
final class SidebarRowHoverTrackingView: NSView {
    var rowID: UUID
    var coordinator: SidebarHoverCoordinator
    var setHovered: @MainActor (Bool) -> Void
    private var lastReportedFrame: CGRect?

    init(
        rowID: UUID,
        coordinator: SidebarHoverCoordinator,
        setHovered: @escaping @MainActor (Bool) -> Void
    ) {
        self.rowID = rowID
        self.coordinator = coordinator
        self.setHovered = setHovered
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshRegistration()
    }

    override func layout() {
        super.layout()
        let frameInSuperview = frame
        guard lastReportedFrame != frameInSuperview else { return }
        lastReportedFrame = frameInSuperview
        coordinator.rowViewFrameDidChange(self, rowID: rowID)
    }

    func refreshRegistration() {
        if window == nil {
            setHovered(false)
            coordinator.unregisterRowView(self, rowID: rowID)
        } else {
            coordinator.registerRowView(
                self,
                rowID: rowID,
                setHovered: setHovered
            )
        }
    }
}
