import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// What a joined machine's menu does (its "…" button). Each is a registered action
/// (`machine.joined.<rawValue>`, `ActionMenuContext.joinedMachine`) the App binds.
public nonisolated enum JoinedMachineAction: String, CaseIterable, Sendable {
    /// `machine doctor ID` in the Check Machine checklist.
    case check
    /// A new credential for it (the old one stops working).
    case rotate
    /// Revoke… (asks first): it leaves the team's machines.
    case revoke

    /// Whether the action can run on a machine in `state` (a revoked machine can only be checked).
    public func isAvailable(for state: JoinedMachine.State) -> Bool {
        self == .check || state != .revoked
    }
}

/// A joined machine's row in the Machines section (``MachineSectionView``): its kind's icon, its name
/// with the last Check's mark, its state and who made its line, and the app's more button
/// (`OverflowButton`) that shows on hover. The button's hover fill covers the button alone, never
/// the row, and it stays shown and lit while its menu is open. The menu opens on the press with no
/// fade-in; its rows are the action registry's (`Actions.menu`). It takes a value snapshot and an
/// action bundle, never a store.
final class JoinedMachineRowView: NSView {
    /// What the row shows.
    struct Snapshot: Equatable {
        var id: String
        var name: String
        var caption: String
        /// The last Revoke or Rotate failed: the caption is the failure, in the danger color.
        var failed: Bool
        var health: HostHealth?
        var healthHelp: String?
        /// A Revoke or Rotate runs: a spinner in place of the more button.
        var busy: Bool
        /// The menu is shown open (the capture fixture's; a real open menu lights the button itself).
        var menuOpen: Bool
        /// The app also connects to it, so New Workspace can open one there.
        var isLinked: Bool
        var isConnected: Bool
        /// The row's icon: its kind's (the link's for a linked machine, else the joined kind's).
        var icon: IconName

        init(row: MachineSectionRow, machine: JoinedMachine, busy: Bool, failed: JoinedMachineChange?, menuOpen: Bool) {
            id = machine.id
            name = row.name
            caption = JoinedMachineStrings.caption(machine, failed: failed)
            self.failed = failed != nil
            health = row.health
            healthHelp = row.healthHelp
            self.busy = busy
            self.menuOpen = menuOpen
            isLinked = row.isLinked
            isConnected = row.isConnected
            icon = row.kind.icon
        }
    }

    /// What the row's controls do.
    struct Actions {
        /// New Workspace on the machine (`workspace.newOnMachine`).
        var newWorkspace: @MainActor () -> Void = {}
        /// The more button's menu, made when it opens (nil: no menu).
        var menu: @MainActor () -> NSMenu? = { nil }
    }

    private let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    private let healthMark = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let text = NSView()
    let more = OverflowButton(label: "")
    let spinner = StatusIndicatorView.spinner()
    let add = NSButton(title: "", target: nil, action: nil)
    private(set) var snapshot: Snapshot?
    private var actions = Actions()
    /// Hover from where the pointer and the row are now, not from enter and exit events alone: a
    /// row laid out, scrolled or shown under a still pointer gets no enter (cx-ww20).
    private var pointerHover: PointerHover?
    private var hovered = false
    private var heldOpen = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: JoinedMachineMetrics.rowHeight))
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        caption.font = Typography.caption
        caption.lineBreakMode = .byTruncatingTail
        for label in [name, caption] { label.cell?.truncatesLastVisibleLine = true }
        add.isBordered = false
        add.image = NSImage.icon(.actionAdd, size: Metrics.smallIconSize)
        add.imagePosition = .imageOnly
        add.target = self
        add.action = #selector(newWorkspace)
        add.setAccessibilityLabel(AddMachineStrings.newWorkspace)
        // The workspace action is hover chrome: keep the row quiet until the pointer or its menu
        // asks for an action, matching the ordinary machine row.
        add.alphaValue = 0
        more.pressMenu = { [weak self] in self?.actions.menu() }
        // A menu's tracking swallows the exit: read the pointer again once it closes.
        let present = more.presentMenu
        more.presentMenu = { [weak self] menu, button in
            self?.heldOpen = true
            self?.more.showsMenu = true
            self?.reveal()
            defer {
                self?.heldOpen = false
                self?.more.showsMenu = false
                self?.reveal()
            }
            present(menu, button)
            self?.pointerHover?.refresh()
        }
        text.setAccessibilityElement(true)
        text.setAccessibilityRole(.staticText)
        for view in [icon, name, healthMark, caption, more, spinner, add] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
        }
        ([name, healthMark, caption] as [NSView]).forEach(text.addSubview)
        ([icon, text, more, spinner, add] as [NSView]).forEach(addSubview)
        pointerHover = PointerHover(self) { [weak self] hovering in self?.setHovered(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: JoinedMachineMetrics.rowHeight) }

    /// Shows `snapshot` and wires `actions`.
    func update(_ snapshot: Snapshot, _ actions: Actions) {
        self.actions = actions
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        icon.image = NSImage.icon(snapshot.icon, size: Metrics.iconSize)
        name.stringValue = snapshot.name
        caption.stringValue = snapshot.caption
        more.label = JoinedMachineStrings.more(snapshot.name)
        more.setAccessibilityIdentifier("cmux.machines.joined.more.\(snapshot.id)")
        text.themedToolTip = snapshot.healthHelp
        text.setAccessibilityLabel([snapshot.name, snapshot.caption, snapshot.healthHelp ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        // Workspaces need a link to the machine; one reached through the mesh alone has none.
        add.isEnabled = snapshot.isLinked && snapshot.isConnected
        add.themedToolTip = snapshot.isLinked ? nil : JoinedMachineStrings.noWorkspace
        // The fixture's open menu lights the button as a press does; a real press lights it itself.
        if snapshot.menuOpen != heldOpen {
            heldOpen = snapshot.menuOpen
            more.hover.state.pressed = heldOpen
        }
        applyColors()
        reveal()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds, inset = Metrics.panelInset, side = JoinedMachineMetrics.buttonSide
        let iconSide = Metrics.iconSize
        icon.frame = NSRect(x: inset, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
        var x = b.width - inset - side
        add.frame = NSRect(x: x, y: (b.height - side) / 2, width: side, height: side)
        x -= side + Metrics.space1
        more.frame = NSRect(x: x, y: (b.height - side) / 2, width: side, height: side)
        let spin = JoinedMachineMetrics.spinnerSize
        spinner.frame = NSRect(x: x + (side - spin) / 2, y: (b.height - spin) / 2, width: spin, height: spin)
        let textX = icon.frame.maxX + inset
        text.frame = NSRect(x: textX, y: 0, width: max(0, x - inset - textX), height: b.height)
        // The cell's size: a truncating label's intrinsic width is not its text's width.
        let nameSize = name.cell?.cellSize ?? .zero, captionSize = caption.cell?.cellSize ?? .zero
        let nameHeight = ceil(nameSize.height), captionHeight = ceil(captionSize.height)
        let top = (b.height + nameHeight + captionHeight + 1) / 2
        let dot = snapshot?.health == nil ? 0 : JoinedMachineMetrics.healthSize
        let nameWidth = min(ceil(nameSize.width), max(0, text.frame.width - (dot > 0 ? dot + Metrics.space2 : 0)))
        name.frame = NSRect(x: 0, y: top - nameHeight, width: nameWidth, height: nameHeight)
        healthMark.frame = NSRect(x: name.frame.maxX + Metrics.space2, y: name.frame.midY - dot / 2, width: dot, height: dot)
        caption.frame = NSRect(x: 0, y: name.frame.minY - 1 - captionHeight, width: text.frame.width, height: captionHeight)
        // The row may have moved under a still pointer.
        pointerHover?.refresh()
    }

    /// A row put in a window (the section showing) or taken out reads the pointer again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerHover?.refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func newWorkspace() { actions.newWorkspace() }

    /// The row's text as shown: its name, then its caption (tests and the section's `shownLines`).
    var shownText: String { [name.stringValue, caption.stringValue].filter { !$0.isEmpty }.joined(separator: " · ") }

    /// `PointerHover`'s answer (tests set it as a pointer would).
    func setHovered(_ on: Bool) {
        guard on != hovered else { return }
        hovered = on
        reveal()
    }

    /// The more button shows on hover and while its menu is open; a running change shows the spinner.
    private func reveal() {
        let busy = snapshot?.busy ?? false
        // The spinner shows and hides itself with its spin.
        spinner.spin(busy)
        more.isHidden = busy
        more.alphaValue = hovered || heldOpen ? 1 : 0
        add.alphaValue = hovered || heldOpen ? 1 : 0
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = Palette.textSecondary
            name.textColor = Palette.textPrimary
            caption.textColor = snapshot?.failed == true ? Palette.danger : Palette.textSecondary
            add.contentTintColor = Palette.textSecondary
            healthMark.image = JoinedMachineHealthMark.image(snapshot?.health)
            healthMark.contentTintColor = Palette.success
        }
    }
}

/// The last Check's mark beside a joined machine's name, as the section's other rows draw it: a
/// check in the success color, or a dot in the attention or danger color.
@MainActor
enum JoinedMachineHealthMark {
    static func image(_ health: HostHealth?) -> NSImage? {
        let side = JoinedMachineMetrics.healthSize
        switch health {
        // A template: the image view tints it in the success color.
        case .ok: return NSImage.icon(.statusComplete, size: side)
        case .warning: return dot(Palette.attention, side: side)
        case .failing: return dot(Palette.danger, side: side)
        case nil: return nil
        }
    }

    private static func dot(_ color: NSColor, side: CGFloat) -> NSImage {
        let dot = AddMachineMetrics.dotSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - dot / 2, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
            return true
        }
    }
}

@MainActor
enum JoinedMachineMetrics {
    /// The more and New Workspace buttons' square: the sidebar controls' hit target.
    static var buttonSide: CGFloat { Metrics.iconSize + Metrics.space2 }
    static let spinnerSize: CGFloat = 14
    static var healthSize: CGFloat { AddMachineMetrics.dotSize * 2 }
    /// A name line, a caption line and 2 pt above and below, as the section's other rows.
    static var rowHeight: CGFloat {
        let lines = NSLayoutManager()
        return ceil(lines.defaultLineHeight(for: Typography.body)) + ceil(lines.defaultLineHeight(for: Typography.caption)) + 1 + 4
    }
}

/// What the App shows around a joined machine's actions: Revoke's question, and why an action
/// cannot run (Labs off, a change already running).
extension JoinedMachineAction {
    /// Revoke's question: its title, its body (the heartbeat bound) and its button.
    public static func revokePrompt(_ name: String) -> (title: String, body: String, button: String) {
        (JoinedMachineStrings.revokeTitle(name), JoinedMachineStrings.revokeBody, JoinedMachineStrings.revokeButton)
    }

    /// Why a joined machine's action does nothing: Labs `labs.machineJoin` is off.
    public static var labsOff: String { JoinedMachineStrings.labsOff }
    /// Why Rotate or Revoke waits: another change on the machine is still running.
    public static var busy: String { JoinedMachineStrings.busy }
}

/// Text of the joined rows (Resources/AddMachine.xcstrings).
nonisolated enum JoinedMachineStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }

    /// How long a revoked machine keeps access at most: the platform's heartbeat interval. Every
    /// heartbeat and relay request checks live revocation, so it is cut off at the next one.
    static let heartbeatSeconds = 30

    static func caption(_ machine: JoinedMachine, failed: JoinedMachineChange?) -> String {
        if let failed {
            return failed == .revoke ? s("machines.joined.revokeFailed", "Could not revoke it. Try again.")
                : s("machines.joined.rotateFailed", "Could not rotate its credential. Try again.")
        }
        let state = switch machine.state {
        case .online: s("machines.joined.online", "Online")
        case .offline: s("machines.joined.offline", "Offline")
        case .revoked: s("machines.joined.revoked", "Revoked")
        }
        guard let by = machine.mintedBy else { return state }
        return state + " · " + String(format: s("machines.joined.mintedBy", "added by %@"), by)
    }

    static func more(_ name: String) -> String { String(format: s("machines.joined.more", "More for %@"), name) }
    static var noWorkspace: String { s("machines.joined.noWorkspace", "Reached through the mesh; workspaces need a link") }
    /// A joined machine's action asked to run after Labs `labs.machineJoin` turned off.
    static var labsOff: String { s("machines.joined.labsOff", "Joined machines are off in Labs.") }
    static var busy: String { s("machines.joined.busy", "Wait for the last change on this machine to finish.") }

    static func revokeTitle(_ name: String) -> String { String(format: s("machines.joined.revokeTitle", "Revoke %@?"), name) }
    static var revokeBody: String {
        String(format: s("machines.joined.revokeBody", "It leaves your team's machines. Its access ends on its next heartbeat, within %lld seconds. To use it again, paste a new line on it."),
               heartbeatSeconds)
    }
    static var revokeButton: String { s("machines.joined.revokeButton", "Revoke") }
}
