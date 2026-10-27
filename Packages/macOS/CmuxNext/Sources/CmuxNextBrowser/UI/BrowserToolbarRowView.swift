import AppKit
import CmuxNextDesign

/// The browser toolbar row (`BrowserChromeView.toolbar`): Back, Forward and
/// Reload, the omnibar, the extension slot and the toolbar buttons, placed by
/// frame layout from `ToolbarRowLayout` (Chrome's `ToolbarView::Layout`). The
/// arrow shows over the whole row (`ArrowCursorView`).
final class BrowserToolbarRowView: ArrowCursorView {
    private let navigation: [ChromeIconButton]
    private let addressBar: AddressBarView
    private let slot: ToolbarSlotView
    private let buttons: BrowserToolbarButtonsView

    /// Token-derived sizes; the chrome sets them from its density binding.
    var metrics: ToolbarRowLayout.Metrics? {
        didSet { if metrics != oldValue { needsLayout = true } }
    }

    /// The edge the row sits on: the omnibar keeps its gap from that edge.
    var position: ToolbarPosition = .top {
        didSet { if position != oldValue { needsLayout = true } }
    }

    init(navigation: [ChromeIconButton], addressBar: AddressBarView, slot: ToolbarSlotView, buttons: BrowserToolbarButtonsView) {
        (self.navigation, self.addressBar, self.slot, self.buttons) = (navigation, addressBar, slot, buttons)
        super.init(frame: .zero)
        for view in (navigation as [NSView]) + [addressBar, slot, buttons] { addSubview(view) }
        slot.onContentChange = { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The row's frames for its size and content now.
    var rowLayout: ToolbarRowLayout? {
        guard let metrics else { return nil }
        let slotCount = slot.arrangedSubviews.filter { !$0.isHidden }.count
        let slotWidth = ButtonLineLayout(count: slotCount, button: metrics.buttonSize, spacing: slot.spacing, height: metrics.buttonSize).width
        return ToolbarRowLayout(ToolbarRowLayout.Input(
            size: bounds.size, position: position, navigationButtons: navigation.filter { !$0.isHidden }.count,
            trailing: ToolbarRowLayout.Trailing(slotWidth: slotWidth, buttonsWidth: buttons.shownWidth), metrics: metrics
        ))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let row = rowLayout else { return }
        let mapping = chromeFrameMapping
        for (button, rect) in zip(navigation.filter { !$0.isHidden }, row.navigation) { button.setChromeFrame(mapping.map(rect)) }
        addressBar.setChromeFrame(mapping.map(row.address))
        slot.setChromeFrame(mapping.map(row.slot))
        buttons.setChromeFrame(mapping.map(row.buttons))
    }
}

/// The toolbar's extension slot (`BrowserChromeView.extensionSlot`): a stack
/// of toolbar-sized buttons that `ExtensionActionToolbar` fills. Its row
/// places it by frame, so it reports every button added or removed.
final class ToolbarSlotView: NSStackView {
    var onContentChange: (() -> Void)?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        onContentChange?()
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        onContentChange?()
    }
}
