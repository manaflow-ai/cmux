public import AppKit
import CmuxNextDesign

/// The sidebar's edit mode (Leo 2026-10-20, as an iPhone's home screen): right-click the sidebar >
/// Edit Sidebar (or the palette's), and its items wiggle. A drag moves one (the bands' own drag), its
/// ✕ or Delete takes it out (the menu's Remove, one undo step), Add Items opens App Store Features on
/// Sidebar (`SidebarIntent.addItems`), and Done (or Escape on a focused item) ends it.
extension SidebarView {
    public var isEditingItems: Bool { editBar != nil }

    public func setEditingItems(_ on: Bool) {
        guard on != isEditingItems else { return }
        if on {
            let bar = SidebarEditBar()
            bar.onAdd = { [weak self] in self?.model.send(.addItems) }
            bar.onDone = { [weak self] in self?.setEditingItems(false) }
            addSubview(bar)
            editBar = bar
        } else {
            editBar?.removeFromSuperview()
            editBar = nil
        }
        // The footer (Settings, the profile control) stays as it is: it is not the person's to take out.
        for region in bandRegions + list.blockRegions { region.isEditing = on && region !== footerRegion }
        needsLayout = true
    }

    /// The bar floats over the bottom of the workspace list, inset as the rows are.
    func layoutEditBar(over list: CGRect) {
        guard let editBar else { return }
        let height = editBar.fittingSize.height, inset = SidebarStyle.horizontalInset
        editBar.frame = NSRect(x: list.minX + inset, y: list.maxY - height - Metrics.space2,
                               width: max(0, list.width - inset * 2), height: height)
    }
}

/// Edit mode's bar: Add Items, then Done. No Escape keycap: a pane keeps the key while it has focus.
final class SidebarEditBar: NSView {
    var onAdd: (() -> Void)?
    var onDone: (() -> Void)?
    let add = ThemedBezelButton()
    let done = ThemedBezelButton()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius + Metrics.space1
        add.title = Strings.editAddItems
        done.title = Strings.editDone
        for (button, action) in [(add, #selector(addPressed)), (done, #selector(donePressed))] {
            button.target = self
            button.action = action
            addSubview(button)
        }
        add.setAccessibilityIdentifier("cmux.sidebar.edit.add")
        done.setAccessibilityIdentifier("cmux.sidebar.edit.done")
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(add.fittingSize.height, done.fittingSize.height) + Metrics.space1 * 2)
    }

    override func layout() {
        super.layout()
        let a = add.fittingSize, d = done.fittingSize, pad = Metrics.space1
        add.frame = NSRect(x: pad, y: (bounds.height - a.height) / 2, width: a.width, height: a.height)
        done.frame = NSRect(x: bounds.width - pad - d.width, y: (bounds.height - d.height) / 2, width: d.width, height: d.height)
    }

    override func updateLayer() {
        // The sidebar cards' neutral veil over the sidebar's glass (`CardSurfaceView`), never a solid
        // bar (Leo 2026-10-21: "STOP DOING SOLID"); solid only under Reduce Transparency.
        let veil = FloatingGlassStyle.card.look(isDark: themeTokens.isDark).veil.nsColor
        let opaque = ReduceTransparency.shared.isEnabled
        performWithTheme {
            // glass-opaque-allow: Reduce Transparency draws every surface solid.
            layer?.backgroundColor = (opaque ? Palette.elevatedBackground : veil).cgColor
            layer?.borderColor = Palette.separator.cgColor
            layer?.borderWidth = Metrics.lineWidth(1)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func addPressed() { onAdd?() }
    @objc private func donePressed() { onDone?() }
}
