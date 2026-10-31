import AppKit

/// The x at the trailing edge of one list row while the pointer is over it: Messages' New
/// Message row, whose x discards the draft. It lives in the list's document view, so it
/// scrolls with its row; the vendored list keeps no hover of its own (Messages draws none on
/// other rows), so this owns the one tracking area that follows the pointer over the rows. A
/// scroll under a still pointer carries the x with its row; the next pointer move re-checks.
@MainActor
final class CmuxSidebarRowClose: NSResponder {
    /// The circled x; hidden until the pointer is over the ``rowID`` row.
    let button = CmuxSidebarRowCloseButton()
    /// The row that shows the x; nil shows it nowhere.
    var rowID: String? { didSet { if rowID != oldValue { refresh() } } }
    /// The x was clicked on the ``rowID`` row (its id).
    var onClose: (String) -> Void = { _ in }

    private weak var list: CmuxSidebarView?
    /// The pointer's last place in the document view, or nil while it is outside the list.
    private var pointer: CGPoint?

    /// The x's side and its distance from the row's trailing edge (the time's inset).
    static let side: CGFloat = 18
    static let trailingInset: CGFloat = SidebarMetrics.textRightInset

    init(list: CmuxSidebarView) {
        self.list = list
        super.init()
        button.isHidden = true
        button.target = self
        button.action = #selector(closeClicked)
        let document = list.controller.document
        document.addSubview(button)
        // .inVisibleRect: one area that follows the document's visible part as it scrolls. The
        // area does not retain its owner: the list holds this for as long as its document lives.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        document.addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { move(event) }
    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        refresh()
    }

    private func move(_ event: NSEvent) {
        guard let document = list?.controller.document else { return }
        pointer = document.convert(event.locationInWindow, from: nil)
        refresh()
    }

    /// The ``rowID`` row's rect in the document view, or nil when the list does not show it as
    /// a row (absent, a pinned tile, or the avatar-only list, which has no room for an x).
    var rowRect: CGRect? {
        guard let list, let rowID else { return nil }
        let controller = list.controller
        guard !controller.metrics.compact else { return nil }
        for (r, i) in controller.rowItems.enumerated() where SidebarController.element(controller.snapshot.items, i)?.id == rowID {
            return controller.rowRect(r)
        }
        return nil
    }

    /// Places the x on the row under the pointer, or hides it. Also runs after every `show`
    /// (the row can move, go, or come back under a still pointer).
    func refresh() {
        guard let row = rowRect, let pointer, row.contains(pointer) else {
            button.isHidden = true
            return
        }
        let side = Self.side
        button.frame = CGRect(x: row.maxX - Self.trailingInset - side, y: (row.midY - side / 2).rounded(), width: side, height: side)
        button.isHidden = false
    }

    @objc private func closeClicked() {
        guard let rowID else { return }
        button.isHidden = true
        onClose(rowID)
    }
}

/// Messages' row x: a filled grey circle with a white x, no bezel, taking the first click in
/// an inactive window as the row does.
final class CmuxSidebarRowCloseButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        contentTintColor = .secondaryLabelColor
        setButtonType(.momentaryChange)
        setAccessibilityIdentifier("cmux.home.sidebar.rowClose")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
