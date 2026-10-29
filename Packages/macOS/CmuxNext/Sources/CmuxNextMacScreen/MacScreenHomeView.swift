public import AppKit
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextWakeups

/// What the home page asks of its owner.
public struct MacScreenHomeActions {
    /// Show one of the user's devices in this tab, asking the hub for the scope (nil: the Connect card).
    public var openDevice: (String, SessionScope?) -> Void = { _, _ in }
    /// Show one of the user's devices in a new tab.
    public var openDeviceInNewTab: (String, SessionScope?) -> Void = { _, _ in }

    public init() {}
}

/// Mac Screen's home page (AppKit, plans/cmux-next/no-swiftui-DESIGN.md): the
/// user's devices from the device hub, Allow Mac Screen on This Mac, and the
/// keyboard setting. Mac Screen works only through the device hub (pairing
/// links are gone): without one, or signed out, the page says how to set it
/// up. Drawn in the tab's theme (`MacScreenColors`, `MacScreenType`).
///
/// It reads what it shows into a value (`MacScreenHomeSnapshot`) under
/// Observation and builds its rows again only when that value changes; every
/// control calls the models (`MacScreenHomeActions`, the hub host, the
/// system shortcut tap) directly, as a person's press.
@MainActor
final class MacScreenHomeView: MacScreenThemedView {
    let host: MacScreenShareHost
    let actions: MacScreenHomeActions
    let systemShortcuts: MacScreenSystemShortcuts?
    let devices: MacScreenHomeDevices?
    /// The app's main-thread scheduler: the page's model follow and its switches' resync.
    private let mainWork: MainWorkScheduler
    private let scroll = NSScrollView()
    private let document = MacScreenFlippedView()
    private let column = MacScreenStack.make(.vertical, spacing: 28, alignment: .leading)
    /// What the rows show now (nil before the first build).
    private(set) var shown: MacScreenHomeSnapshot?
    /// Reads the permissions of the hosts listed (this Mac's access to each).
    private var permissionsRead: Task<Void, Never>?
    private var readFor: [String] = []
    private var builtWithBorders = true
    /// What the page shows (`render(_:)` on a change).
    private var watch: FrameObservation<MacScreenHomeSnapshot?>?
    /// `.frame(maxWidth: 620).padding(.horizontal, 32)`: the column's width for the page's.
    private lazy var columnWidth = column.widthAnchor.constraint(equalToConstant: 620)

    /// The page follows its models while `node` (the tab) is visible, on `mainWork`'s frames.
    init(host: MacScreenShareHost, actions: MacScreenHomeActions, node: VisibilityNode, on mainWork: MainWorkScheduler,
         systemShortcuts: MacScreenSystemShortcuts? = nil, devices: MacScreenHomeDevices? = nil) {
        self.host = host
        self.actions = actions
        self.systemShortcuts = systemShortcuts
        self.devices = devices
        self.mainWork = mainWork
        super.init(frame: .zero, node: node)
        setAccessibilityIdentifier("macScreen.home")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        SystemScrollers.follow(scroll)
        // The document is framed by `layout()` (the scroll view's width, the column's height); the
        // column inside it is Auto Layout at a width set from that frame.
        scroll.documentView = document
        document.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 36),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            columnWidth,
        ])
        scroll.frame = bounds
        addSubview(scroll)
        let watch = FrameObservation(owner: "mac-screen.home", delivery: .visible(node), on: mainWork) { [weak self] in
            self.map(MacScreenHomeSnapshot.init(home:))
        } onChange: { [weak self] snapshot in
            if let snapshot { self?.render(snapshot) }
        }
        self.watch = watch
        if let snapshot = watch.value { render(snapshot) }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutPage()
    }

    /// The page follows its own size at once (a pane resize, a split), not only on a layout pass.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPage()
    }

    /// Frames the scroll view to the page, sets the column's width from it and frames the
    /// document to the column's height (`.frame(maxWidth: 620).padding(32, 36)`, centered).
    func layoutPage() {
        if scroll.frame != bounds { scroll.frame = bounds }
        let width = scroll.contentSize.width
        let target = max(0, min(620, width - 64))
        if abs(columnWidth.constant - target) > 0.5 { columnWidth.constant = target }
        // Wrapping labels learn their width from one pass and report their height to the next.
        for _ in 0..<4 {
            // sync-layout: fitLines below reads each wrapping label's laid-out width.
            column.layoutSubtreeIfNeeded()
            var changed = false
            for case let label as MacScreenText in views(under: column) where label.fitLines() { changed = true }
            if !changed { break }
        }
        let height = max(scroll.contentSize.height, ceil(column.fittingSize.height) + 72)
        let size = NSSize(width: width, height: height)
        if document.frame.size != size { document.setFrameSize(size) }
    }

    override func colorsChanged() {
        wantsLayer = true
        layer?.backgroundColor = colors.page.cgColor
        // Hairlines between device rows come and go with `appearance.borders`.
        if colors.borders != builtWithBorders, let shown { build(shown) }
        super.colorsChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // The page left: its read of the hosts' permissions ends, and runs again when it is back.
            permissionsRead?.cancel()
            permissionsRead = nil
            readFor = []
            return
        }
        // The page appears: read the permissions again (granted in System Settings meanwhile).
        Task { [host] in await host.refreshPermissions() }
        systemShortcuts?.refreshAccessibility()
        readPermissions(shown?.deviceIDs ?? [])
    }

    // MARK: Drawing

    /// Builds the rows when the page's state changed.
    private func render(_ snapshot: MacScreenHomeSnapshot) {
        guard snapshot != shown else { return }
        let hadSharing = shown?.sharing != nil
        shown = snapshot
        build(snapshot)
        if snapshot.sharing != nil, !hadSharing, window != nil { Task { [host] in await host.refreshPermissions() } }
        readPermissions(snapshot.deviceIDs)
    }

    /// A switch shows its model's value, not the click: after a press, on the next turn (never
    /// inside the switch's own event), it shows what the model says until the model's write lands.
    func syncSwitchesSoon() {
        // The rest of the person's press: one userBlocking task, which runs after the switch's event returns.
        mainWork.post(.userBlocking, owner: "MacScreenHome.syncSwitches") { [weak self] in self?.syncSwitches() }
    }

    private func syncSwitches() {
        for view in views(under: column) {
            guard let toggle = view as? MacScreenSwitch else { continue }
            switch toggle.accessibilityIdentifier() {
            case "macScreen.home.allowToggle": toggle.isOn = devices?.hubHost.isSharing ?? false
            case "macScreen.home.systemShortcuts": toggle.isOn = systemShortcuts?.enabled ?? false
            default: break
            }
        }
    }

    private func views(under root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + views(under: $0) }
    }

    private func build(_ snapshot: MacScreenHomeSnapshot) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        builtWithBorders = colors.borders
        needsLayout = true
        layoutPage()
        MacScreenStack.addFullWidth(header(), to: column)
        if let list = snapshot.devices { MacScreenStack.addFullWidth(yourDevices(list), to: column) }
        if let sharing = snapshot.sharing { MacScreenStack.addFullWidth(sharingSection(sharing), to: column) }
        if let keyboard = snapshot.keyboard { MacScreenStack.addFullWidth(keyboardSection(keyboard), to: column) }
        paint(column)
    }

    private func header() -> NSView {
        let title = MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
            MacScreenGlyph("display", font: MacScreenType.title, ink: \.primary),
            MacScreenText(L.t("macScreen.home.title", "Mac Screen"), font: MacScreenType.title),
        ])
        let column = MacScreenStack.make(.vertical, spacing: 6, alignment: .leading)
        column.addArrangedSubview(title)
        MacScreenStack.addFullWidth(MacScreenText(L.t("macScreen.home.subtitle", "See and control your other Macs from a cmux tab."),
                                                  font: MacScreenType.subtitle, ink: \.secondary, wraps: true), to: column)
        return column
    }

    /// This Mac's access to each host is that host's permission list: read it for the hosts shown, again when they change.
    private func readPermissions(_ ids: [String]) {
        guard window != nil, ids != readFor else { return }
        readFor = ids
        permissionsRead?.cancel()
        permissionsRead = nil
        guard !ids.isEmpty, let hub = devices?.box.hub else { return }
        // task-owner: one read of the listed hosts' permissions; cancelled when the list changes or the page goes.
        // Off main: each read is the hub's own main-actor request, which applies its answer in the hub's job.
        permissionsRead = Task { @concurrent in
            for id in ids {
                guard !Task.isCancelled else { return }
                await hub.refreshPermissions(host: id)
            }
        }
    }

    // MARK: Keyboard

    /// Send System Shortcuts to the Remote Mac, and the Accessibility it needs.
    private func keyboardSection(_ keyboard: MacScreenHomeSnapshot.Keyboard) -> NSView {
        let content = MacScreenHomeParts.cardColumn()
        let toggle = MacScreenHomeParts.switchRow(
            title: L.t("macScreen.home.systemShortcuts", "Send system shortcuts to the remote Mac"),
            detail: L.t("macScreen.home.systemShortcutsDetail", "While a Mac’s screen has the keyboard, ⌘Tab, ⌘Space, Mission Control, Spaces, screenshots and ⌘Q, ⌘W, ⌘H, ⌘M go to that Mac. ⌃⌥⎋ still releases the keyboard."),
            isOn: keyboard.enabled, id: "macScreen.home.systemShortcuts"
        ) { [weak self] on in
            self?.systemShortcuts?.setEnabled(on)
            self?.syncSwitchesSoon()
        }
        MacScreenStack.addFullWidth(toggle, to: content)
        if keyboard.needsAccessibility {
            MacScreenStack.addFullWidth(MacScreenFill.divider(), to: content)
            let row = MacScreenHomeParts.permissionRow(
                title: L.t("macScreen.home.accessibility", "Accessibility"),
                detail: L.t("macScreen.home.systemShortcutsAccessibility", "Lets cmux take system shortcuts before macOS does, to send them to the other Mac."),
                granted: false, action: L.t("macScreen.home.allowAccessibility", "Allow Accessibility"),
                id: "macScreen.home.systemShortcutsAccessibility"
            ) { [weak self] in self?.systemShortcuts?.requestAccessibility() }
            MacScreenStack.addFullWidth(row, to: content)
        }
        return MacScreenHomeParts.section(L.t("macScreen.home.keyboardTitle", "Keyboard"), content: content)
    }
}

/// A top-down document view for a scroll view.
@MainActor
final class MacScreenFlippedView: NSView {
    override var isFlipped: Bool { true }
}
