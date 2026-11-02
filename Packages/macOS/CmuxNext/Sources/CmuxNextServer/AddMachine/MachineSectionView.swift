public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The right sidebar's Machines section (AppKit): this Mac, then a header per kind (Cloud, SSH,
/// Servers, Joined) over its machines, then Add Machine…, laid out as ``MachineSectionStyle`` says. Every
/// icon sits in one column and every name starts on one line; text takes three theme inks
/// (``MachineSectionInk``). A machine that joined with a one-line token (Labs `labs.machineJoin`) is
/// a ``JoinedMachineRowView`` with its "…" menu, in its link's group or the Joined group. Rows take
/// value snapshots and an action bundle, never a store.
public final class MachineSectionView: NSView {
    /// What the section's controls do.
    public struct Actions {
        /// New Workspace on a machine (`workspace.newOnMachine`'s `machine`).
        public var newWorkspace: @MainActor (String) -> Void
        /// Add Machine… (`device.add`).
        public var addMachine: @MainActor () -> Void
        /// A machine's right-click row New Workspace on This Machine, from the action registry (a
        /// registered action, never an inline selector); nil leaves the row without a menu.
        public var newWorkspaceMenuItem: @MainActor (String) -> NSMenuItem?
        /// A joined machine's "…" menu (the registry's rows for it), with the row it opens on.
        public var joinedMenu: @MainActor (JoinedMachine, MachineSectionRow) -> NSMenu?

        public init(newWorkspace: @escaping @MainActor (String) -> Void, addMachine: @escaping @MainActor () -> Void,
                    newWorkspaceMenuItem: @escaping @MainActor (String) -> NSMenuItem? = { _ in nil },
                    joinedMenu: @escaping @MainActor (JoinedMachine, MachineSectionRow) -> NSMenu? = { _, _ in nil }) {
            self.newWorkspace = newWorkspace
            self.addMachine = addMachine
            self.newWorkspaceMenuItem = newWorkspaceMenuItem
            self.joinedMenu = joinedMenu
        }
    }

    /// What the joined machines' rows show beside their machine, by joined machine id: a Revoke or
    /// Rotate in flight, the last one that failed, and the menu shown open (the capture fixture's).
    public struct JoinedRowState: Equatable, Sendable {
        public var busy: Set<String>
        public var failed: [String: JoinedMachineChange]
        public var openMenu: String?

        public init(busy: Set<String> = [], failed: [String: JoinedMachineChange] = [:], openMenu: String? = nil) {
            self.busy = busy
            self.failed = failed
            self.openMenu = openMenu
        }

        /// `store`'s state now (read where the caller observes it).
        @MainActor
        public init(_ store: JoinedMachineStore) {
            self.init(busy: store.busy, failed: store.failed, openMenu: store.openMenu)
        }
    }

    private let actions: Actions
    let addRow: MachineSectionAddRow
    public private(set) var rows: [MachineSectionRow] = []
    public private(set) var style: MachineSectionStyle = .compact
    public private(set) var joinedState = JoinedRowState()
    /// Row views by machine id, kept across updates so a row under the pointer keeps its hover.
    private(set) var rowViews: [String: MachineSectionRowView] = [:]
    /// Joined machines' row views by row id, kept the same way.
    private(set) var joinedViews: [String: JoinedMachineRowView] = [:]
    /// The shown views top to bottom, each with the gap above it.
    private var arranged: [(view: NSView, gap: CGFloat)] = []
    private var shown = false

    public init(actions: Actions) {
        self.actions = actions
        addRow = MachineSectionAddRow(action: actions.addMachine)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.machinesSection")
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override public var isFlipped: Bool { true }

    /// Shows `rows` in `style`, joined machines' rows with `joined`; nothing changes when all three
    /// are what it shows.
    public func update(_ rows: [MachineSectionRow], style: MachineSectionStyle, joined: JoinedRowState = JoinedRowState()) {
        guard rows != self.rows || style != self.style || joined != joinedState || !shown else { return }
        self.rows = rows
        self.style = style
        joinedState = joined
        rebuild()
    }

    /// The headers' and rows' text as shown, top to bottom (tests and the gallery).
    public var shownLines: [String] {
        arranged.compactMap { item in
            switch item.view {
            case let header as MachineSectionHeaderView: header.label.stringValue
            case let row as MachineSectionRowView: row.shownText
            case let row as JoinedMachineRowView: row.shownText
            case let add as MachineSectionAddRow: add.label.stringValue
            default: nil
            }
        }
    }

    private func rebuild() {
        shown = true
        var next: [(view: NSView, gap: CGFloat)] = []
        var live: [String: MachineSectionRowView] = [:]
        var liveJoined: [String: JoinedMachineRowView] = [:]
        for group in style.groups(rows) {
            if let title = group.title {
                next.append((MachineSectionHeaderView(title: title), next.isEmpty ? 0 : Metrics.space4))
            }
            for row in group.rows {
                let view: NSView
                if let machine = row.joined {
                    let joinedView = joinedViews[row.id] ?? JoinedMachineRowView()
                    let newWorkspace = actions.newWorkspace, joinedMenu = actions.joinedMenu
                    joinedView.update(.init(row: row, machine: machine, busy: joinedState.busy.contains(machine.id),
                                            failed: joinedState.failed[machine.id], menuOpen: joinedState.openMenu == machine.id),
                                      .init(newWorkspace: { newWorkspace(row.id) }, menu: { joinedMenu(machine, row) }))
                    liveJoined[row.id] = joinedView
                    view = joinedView
                } else {
                    let rowView = rowViews[row.id] ?? MachineSectionRowView(newWorkspace: actions.newWorkspace,
                                                                            menuItem: actions.newWorkspaceMenuItem)
                    rowView.configure(row, showsStateLine: style.showsStateLine)
                    live[row.id] = rowView
                    view = rowView
                }
                next.append((view, next.last?.view is MachineSectionHeaderView ? Metrics.space1 : 0))
            }
        }
        next.append((addRow, style.groupsByKind && !next.isEmpty ? Metrics.space3 : 0))
        let keep = Set(next.map { ObjectIdentifier($0.view) })
        for item in arranged where !keep.contains(ObjectIdentifier(item.view)) { item.view.removeFromSuperview() }
        for item in next where item.view.superview !== self { addSubview(item.view) }
        arranged = next
        rowViews = live
        joinedViews = liveJoined
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        var y = Metrics.space2
        for item in arranged {
            y += item.gap
            // A machine row is as tall as its name needs at this width (a long name wraps).
            let height = (item.view as? MachineSectionRowView)?.height(forWidth: bounds.width) ?? item.view.intrinsicContentSize.height
            item.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

/// The section's three text inks, from the theme's tokens (no ad-hoc opacities): names in primary;
/// headers, states, icons and actions in secondary; disabled glyphs in tertiary. Read inside the
/// view's theme scope (`performWithTheme`).
enum MachineSectionInk {
    static var primary: NSColor { Palette.textPrimary }
    static var secondary: NSColor { Palette.textSecondary }
    static var tertiary: NSColor { Palette.textTertiary }
}

/// A group header: the kind's name in the header font and the secondary ink, at the section's inset.
final class MachineSectionHeaderView: NSView {
    let label = ChromeLabel(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = Typography.header
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        label.setAccessibilityElement(false)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: label.naturalSize.height)
    }

    override func layout() {
        super.layout()
        let inset = MachineSectionMetrics.inset
        label.place(textX: inset, y: 0, maxTextWidth: bounds.width - 2 * inset)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { label.textColor = MachineSectionInk.secondary }
    }
}

/// One machine: its kind's icon in the icon column, its name (whole: a name too long for its column wraps
/// onto more lines and the row grows, never cut mid-word) and last check, its link state (a second
/// line, or at the trailing edge when it is not connected: a spinner while connecting or resuming, the
/// server's state in words for a paused, failed or deleted Cloud machine), and New
/// Workspace as a trailing button that shows while the pointer is on the row or its menu is open. The
/// button's hover fill covers the button alone. The right-click menu and VoiceOver reach it too.
final class MachineSectionRowView: NSView {
    private let icon = NSImageView()
    let nameLabel = ChromeLabel(labelWithString: "")
    let stateLabel = ChromeLabel(labelWithString: "")
    private let health = MachineHealthMarkView()
    private let spinner = StatusIndicatorView.spinner()
    let newButton: MachineSectionIconButton
    private let newWorkspace: @MainActor (String) -> Void
    private let menuItem: @MainActor (String) -> NSMenuItem?
    private(set) var row = MachineSectionRow(id: "", name: "", isConnected: false, isLocal: false)
    private(set) var showsStateLine = false
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private var menuOpen = false
    private var buttonFocused = false
    private var iconSize: CGFloat = 0

    init(newWorkspace: @escaping @MainActor (String) -> Void, menuItem: @escaping @MainActor (String) -> NSMenuItem? = { _ in nil }) {
        self.newWorkspace = newWorkspace
        self.menuItem = menuItem
        newButton = MachineSectionIconButton(icon: .actionAdd, label: AddMachineStrings.newWorkspace)
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        for label in [nameLabel, stateLabel] {
            label.setAccessibilityElement(false)
        }
        // The name is shown whole (Leo's DEV build cut a long name mid-word, "abc-defghi...-xyz"):
        // it wraps at its column, at a hyphen where it can.
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 0
        stateLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = Typography.body
        stateLabel.font = Typography.caption
        spinner.isHidden = true
        newButton.onPress = { [weak self] in self?.runNewWorkspace() }
        newButton.onFocusChange = { [weak self] focused in
            self?.buttonFocused = focused
            self?.reveal()
        }
        newButton.alphaValue = 0
        for view in [icon, nameLabel, health, stateLabel, spinner, newButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    func configure(_ row: MachineSectionRow, showsStateLine: Bool) {
        guard row != self.row || showsStateLine != self.showsStateLine else { return }
        self.row = row
        self.showsStateLine = showsStateLine
        nameLabel.stringValue = row.name
        stateLabel.stringValue = row.stateText
        // The state shows on its own line, or at the trailing edge only when the link is down.
        stateLabel.isHidden = !showsStateLine && (row.isConnected || row.isConnecting)
        spinner.isHidden = !row.isConnecting
        spinner.spin(row.isConnecting)
        health.health = row.health
        newButton.isEnabled = row.isConnected
        themedToolTip = row.healthHelp
        setAccessibilityLabel(row.accessibilityText)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: AddMachineStrings.newWorkspace, target: self,
                                                                   selector: #selector(accessibilityNewWorkspace))])
        iconSize = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyColors()
    }

    /// The row's text as shown: its name, then its state when it shows.
    var shownText: String {
        ([nameLabel] + (stateLabel.isHidden ? [] : [stateLabel])).map(\.stringValue).joined(separator: " · ")
    }

    /// Whether the trailing spinner shows (a connect or a resume on its way, never a paused machine).
    var showsSpinner: Bool { !spinner.isHidden }

    /// Whether New Workspace is showing (the pointer is on the row, its menu is open, or it has keyboard focus).
    var revealsNewWorkspace: Bool { newButton.alphaValue > 0 }

    private func runNewWorkspace() {
        guard row.isConnected else { return }
        newWorkspace(row.id)
    }

    /// One line high at any width; the section sizes the row with ``height(forWidth:)``.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: .greatestFiniteMagnitude))
    }

    /// The row's height in a section `width` wide: a name too long for its column wraps, and the row
    /// grows to hold its lines.
    func height(forWidth width: CGFloat) -> CGFloat {
        let name = nameHeight(column: columns(width: width).name)
        let text = showsStateLine ? name + Metrics.space1 / 2 + stateLabel.naturalSize.height : name
        return max(MachineSectionMetrics.rowHeight, ceil(text + 2 * Metrics.space2))
    }

    /// The text's columns in a row `width` wide: where the text starts, the width left for the name
    /// (before its health mark, the trailing state, the spinner and New Workspace) and the trailing
    /// state's width (0 when it is on its own line or hidden).
    private func columns(width: CGFloat) -> (textX: CGFloat, name: CGFloat, state: CGFloat) {
        let inset = MachineSectionMetrics.inset
        let textX = inset + MachineSectionMetrics.iconColumn + MachineSectionMetrics.iconGap
        var trailing = width - inset - MachineSectionMetrics.buttonSide - Metrics.space2
        if !spinner.isHidden { trailing -= Metrics.smallIconSize + Metrics.space2 }
        var state: CGFloat = 0
        if !showsStateLine, !stateLabel.isHidden {
            state = min(stateLabel.textWidth, max(0, trailing - textX))
            trailing -= state + Metrics.space2
        }
        let mark = health.health == nil ? 0 : MachineHealthMarkView.side + Metrics.space2
        return (textX, max(0, trailing - textX - mark), state)
    }

    /// The name's height in a column `column` wide: one line when it fits, else its wrapped lines.
    private func nameHeight(column: CGFloat) -> CGFloat {
        guard nameLabel.textWidth > column, column > 0 else { return nameLabel.naturalSize.height }
        return nameLabel.size(forWidth: column + 2 * nameLabel.padding).height
    }

    override func layout() {
        super.layout()
        let inset = MachineSectionMetrics.inset, side = MachineSectionMetrics.iconColumn
        if iconSize != side {
            iconSize = side
            icon.image = NSImage.icon(row.kind.icon, size: side)
        }
        let mid = bounds.midY
        icon.frame = NSRect(x: inset, y: mid - side / 2, width: side, height: side)
        let button = MachineSectionMetrics.buttonSide
        newButton.frame = NSRect(x: bounds.maxX - inset - button, y: mid - button / 2, width: button, height: button)
        var trailing = newButton.frame.minX - Metrics.space2
        if !spinner.isHidden {
            let size = Metrics.smallIconSize
            spinner.frame = NSRect(x: trailing - size, y: mid - size / 2, width: size, height: size)
            trailing = spinner.frame.minX - Metrics.space2
        }
        let column = columns(width: bounds.width), textX = column.textX
        let lineHeight = nameLabel.naturalSize.height, stateHeight = stateLabel.naturalSize.height
        if column.state > 0 {
            stateLabel.place(textX: trailing - column.state, y: mid - stateHeight / 2, maxTextWidth: column.state)
        }
        let nameHeight = nameHeight(column: column.name)
        let textHeight = showsStateLine ? nameHeight + Metrics.space1 / 2 + stateHeight : nameHeight
        let top = mid - textHeight / 2
        let nameWidth = min(nameLabel.textWidth, column.name)
        nameLabel.place(textX: textX, y: top, maxTextWidth: nameWidth)
        nameLabel.frame.size.height = nameHeight
        health.frame = NSRect(x: textX + nameWidth + Metrics.space2, y: top + lineHeight / 2 - MachineHealthMarkView.side / 2,
                              width: MachineHealthMarkView.side, height: MachineHealthMarkView.side)
        if showsStateLine {
            stateLabel.place(textX: textX, y: top + nameHeight + Metrics.space1 / 2, maxTextWidth: trailing - textX)
        }
    }

    // MARK: Hover and menu

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        reveal()
    }

    private func reveal() {
        newButton.alphaValue = pointerInside || menuOpen || buttonFocused ? 1 : 0
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    /// The row's right-click menu: New Workspace on This Machine, the registry's row for
    /// `workspace.newOnMachine` on this machine (disabled while the link is down); nil without one.
    func contextMenu() -> NSMenu? {
        guard let item = menuItem(row.id) else { return nil }
        item.title = AddMachineStrings.newWorkspace
        item.isEnabled = row.isConnected
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
    }

    @objc private func accessibilityNewWorkspace() -> Bool {
        guard row.isConnected else { return false }
        runNewWorkspace()
        return true
    }

    // NSView's willOpenMenu and didCloseMenu do nothing, so these call no super.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menuOpen = true
        reveal()
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        menuOpen = false
        reveal()
    }

    // MARK: Colors

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = MachineSectionInk.secondary
            nameLabel.textColor = row.isConnected ? MachineSectionInk.primary : MachineSectionInk.secondary
            stateLabel.textColor = MachineSectionInk.secondary
        }
        health.needsDisplay = true
    }
}

/// A small icon button in the secondary ink (tertiary when disabled) with the chrome's own hover and
/// pressed fill and its themed focus outline, which cover the button alone. With Full Keyboard Access
/// it takes Tab focus and Space presses it, as a SwiftUI button did; AppKit's blue ring is off.
final class MachineSectionIconButton: NSButton {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    /// What a click or VoiceOver's press does.
    var onPress: (() -> Void)?
    /// The button took (true) or gave up (false) keyboard focus: its row keeps it shown while focused.
    var onFocusChange: ((Bool) -> Void)?
    private let glyph: IconName
    private var renderedSize: CGFloat = 0

    init(icon: IconName, label: String) {
        glyph = icon
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(label)
        themedToolTip = label
        wantsLayer = true
        target = self
        action = #selector(pressed)
        focusRingType = .none
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled == true }, onChange: { [weak self] in self?.needsDisplay = true })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        setFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        setFocused(false)
        return true
    }

    private func setFocused(_ focused: Bool) {
        hover.state.focused = focused
        onFocusChange?(focused)
    }

    @objc private func pressed() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let onPress else { return false }
        onPress()
        return true
    }

    override func layout() {
        super.layout()
        let size = Metrics.smallIconSize
        guard size != renderedSize else { return }
        renderedSize = size
        image = NSImage.icon(glyph, size: size)
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = isEnabled ? MachineSectionInk.secondary : MachineSectionInk.tertiary
        }
        hover.refresh(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        hover.state.pressed = true
        defer { hover.state.pressed = false }
        super.mouseDown(with: event)
    }
}

/// Add Machine… as the section's last row: its icon in the machines' icon column, its text in the
/// body font. The pointer brightens it from the secondary ink to the primary one; it draws no fill.
final class MachineSectionAddRow: NSView {
    private let icon = NSImageView()
    /// The themed focus outline around the icon and the text (never the whole row).
    private let focusOutline = CALayer()
    let label = ChromeLabel(labelWithString: "")
    private let action: @MainActor () -> Void
    private var tracking: NSTrackingArea?
    private var pointerInside = false
    private var iconSize: CGFloat = 0

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(frame: .zero)
        label.stringValue = AddMachineStrings.addMachine
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        addSubview(icon)
        addSubview(label)
        wantsLayer = true
        focusOutline.cornerRadius = Metrics.itemCornerRadius
        focusOutline.cornerCurve = .continuous
        focusOutline.isHidden = true
        focusOutline.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(focusOutline)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(AddMachineStrings.addMachine)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MachineSectionMetrics.rowHeight)
    }

    override func layout() {
        super.layout()
        let inset = MachineSectionMetrics.inset, side = MachineSectionMetrics.iconColumn
        if iconSize != side {
            iconSize = side
            icon.image = NSImage.icon(.actionAdd, size: side)
        }
        icon.frame = NSRect(x: inset, y: bounds.midY - side / 2, width: side, height: side)
        let x = icon.frame.maxX + MachineSectionMetrics.iconGap
        label.place(textX: x, y: bounds.midY - label.naturalSize.height / 2, maxTextWidth: bounds.maxX - inset - x)
        focusOutline.frame = NSRect(x: inset - Metrics.space1, y: 0, width: hitRect.width - inset + Metrics.space1, height: bounds.height)
    }

    // MARK: Keyboard (Full Keyboard Access: Tab focuses it, Space or Return runs it, as a button)

    /// Whether Full Keyboard Access is on (tests set it).
    var keyboardAccess: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }
    override var acceptsFirstResponder: Bool { keyboardAccess() }
    override var canBecomeKeyView: Bool { keyboardAccess() }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focusOutline.isHidden = false
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focusOutline.isHidden = true
        return true
    }

    /// Whether the focus outline shows (tests).
    var showsFocus: Bool { !focusOutline.isHidden }

    override func keyDown(with event: NSEvent) {
        if Self.activates(event) { action() } else { super.keyDown(with: event) }
    }

    /// Space, Return or Enter with no modifier, as a focused button takes them.
    static func activates(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "")
    }

    /// Only the icon and the text take the click and the hover, never the empty width after them.
    private var hitRect: NSRect { NSRect(x: 0, y: 0, width: label.frame.maxX + Metrics.space2, height: bounds.height) }

    /// `point` is in the superview's coordinates (NSView's contract), so it is converted to the row's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hitRect.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: hitRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        applyColors()
    }

    override func mouseUp(with event: NSEvent) {
        guard hitRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            let ink = pointerInside ? MachineSectionInk.primary : MachineSectionInk.secondary
            icon.contentTintColor = ink
            label.textColor = ink
            focusOutline.borderColor = Palette.focusRing.cgColor
            focusOutline.borderWidth = Metrics.lineWidth(1.5)
        }
    }
}

/// A machine's last check as a small mark after its name: a check in the success color when every
/// step passed, a dot in the warning or danger color otherwise, nothing before a check ran.
final class MachineHealthMarkView: NSView {
    /// The mark's slot (the check's side; the dot is `AddMachineMetrics.dotSize`).
    static var side: CGFloat { AddMachineMetrics.dotSize * 2 }
    private let check = NSImageView()

    var health: HostHealth? {
        didSet {
            guard health != oldValue else { return }
            isHidden = health == nil
            check.isHidden = health != .ok
            applyColors()
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        check.isHidden = true
        check.imageScaling = .scaleProportionallyDown
        check.image = NSImage.icon(.statusComplete, size: Self.side)
        addSubview(check)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        check.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { check.contentTintColor = Palette.success }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let health, health != .ok else { return }
        performWithTheme {
            let dot = AddMachineMetrics.dotSize
            (health == .warning ? Palette.attention : Palette.danger).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - dot / 2, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
        }
    }
}

private extension ChromeLabel {
    /// The text's own width on one line (no padding).
    var textWidth: CGFloat { intrinsicContentSize.width }

    /// The padding on each side of the text inside the label's frame.
    var padding: CGFloat { max(0, (naturalSize.width - textWidth) / 2) }

    /// Places the label so its text starts at `x` and is at most `maxTextWidth` wide. A label's frame
    /// is its text plus a padding on each side (``ChromeLabel/naturalSize``), so the frame starts that
    /// padding before `x`: the text lines up with the column, and a text that fits is never truncated.
    func place(textX x: CGFloat, y: CGFloat, maxTextWidth: CGFloat) {
        let natural = naturalSize
        let width = min(textWidth, max(0, maxTextWidth))
        frame = NSRect(x: x - padding, y: y, width: width + 2 * padding, height: natural.height)
    }
}
