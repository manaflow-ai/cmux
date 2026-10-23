public import AppKit
import CmuxNextDesign
public import CmuxNextDevices
import Observation

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
    private let scroll = NSScrollView()
    private let document = MacScreenFlippedView()
    private let column = MacScreenStack.make(.vertical, spacing: 28, alignment: .leading)
    /// What the rows show now (nil before the first build).
    private(set) var shown: MacScreenHomeSnapshot?
    /// Reads the permissions of the hosts listed (this Mac's access to each).
    private var permissionsRead: Task<Void, Never>?
    private var readFor: [String] = []
    private var builtWithBorders = true

    init(host: MacScreenShareHost, actions: MacScreenHomeActions, systemShortcuts: MacScreenSystemShortcuts? = nil,
         devices: MacScreenHomeDevices? = nil) {
        self.host = host
        self.actions = actions
        self.systemShortcuts = systemShortcuts
        self.devices = devices
        super.init(frame: .zero)
        setAccessibilityIdentifier("macScreen.home")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        SystemScrollers.follow(scroll)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(column)
        let width = column.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -64)
        width.priority = .defaultHigh
        let margin = column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 32)
        margin.priority = .init(999)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 36),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            margin,
            width,
        ])
        scroll.frame = bounds
        addSubview(scroll)
        render()
    }

    override var isFlipped: Bool { true }

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
        host.refreshPermissions()
        systemShortcuts?.refreshAccessibility()
        readPermissions(shown?.deviceIDs ?? [])
    }

    // MARK: Drawing

    /// Reads the page's state and builds the rows when it changed; again on every change of what it read.
    private func render() {
        let snapshot = withObservationTracking { MacScreenHomeSnapshot(home: self) } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
        guard snapshot != shown else { return }
        let hadSharing = shown?.sharing != nil
        shown = snapshot
        build(snapshot)
        if snapshot.sharing != nil, !hadSharing, window != nil { host.refreshPermissions() }
        readPermissions(snapshot.deviceIDs)
    }

    /// A switch shows its model's value, not the click: after a press, on the next turn (never
    /// inside the switch's own event), it shows what the model says until the model's write lands.
    func syncSwitchesSoon() {
        Task { @MainActor [weak self] in self?.syncSwitches() }
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
        // task-owner: one read of the listed hosts' permissions; cancelled when the list changes or the page goes
        permissionsRead = Task {
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
