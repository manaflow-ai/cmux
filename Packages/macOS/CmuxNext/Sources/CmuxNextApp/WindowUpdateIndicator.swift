import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The update circle in one window's rail (right above Account) and the
/// pill beside it, over the one `UpdaterService`. Nothing asks: a found
/// update downloads in the background, the circle waits with a download
/// glyph, and a click installs and relaunches ("Installing…"). A check that
/// finds nothing shows a short note that hides itself. The menu has
/// Install and Relaunch, Release Notes and Check for Updates.
@MainActor
final class WindowUpdateIndicator {
    /// How long a note ("cmux Is Up to Date") stays.
    static let noteDuration: Duration = .seconds(3)

    let circle = UpdateIndicatorView()
    let pill = UpdatePillView()
    private let updater: UpdaterService
    private let registry: ActionRegistry
    private weak var column: SidebarRailColumnView?
    private var observation: Task<Void, Never>?
    private var noteTimer: Task<Void, Never>?
    private let menuTarget = MenuTarget()

    init(updater: UpdaterService, registry: ActionRegistry, column: SidebarRailColumnView) {
        self.updater = updater
        self.registry = registry
        self.column = column
        column.accessoryView = circle
        circle.onPress = { [weak updater] in updater?.indicatorClicked() }
        circle.menuProvider = { [weak self] in self?.menu() }
        pill.isHidden = true
        // task-owner: this indicator (cancelled in deinit); event-driven (Observation)
        observation = Task { [weak self, updater] in
            for await phase in Observations({ updater.indicatorPhase }) {
                self?.show(phase)
            }
        }
    }

    isolated deinit {
        observation?.cancel()
        noteTimer?.cancel()
    }

    private func show(_ phase: UpdateIndicatorPhase) {
        column?.showsAccessory = phase.showsCircle
        circle.show(phase, toolTip: phase.toolTip)
        if let text = phase.pillText { showPill(text) } else { pill.isHidden = true }
        if case .note = phase { scheduleNoteDismiss() }
    }

    private func scheduleNoteDismiss() {
        noteTimer?.cancel()
        // task-owner: this indicator; one bounded delay per note, replaced by the next.
        noteTimer = Task { [weak updater] in
            try? await Task.sleep(for: Self.noteDuration)
            guard !Task.isCancelled else { return }
            updater?.dismissIndicatorNote()
        }
    }

    /// The pill to the right of the circle, over the sidebar. A note shows
    /// there even while the circle is hidden (the slot it would take).
    private func showPill(_ text: String) {
        pill.text = text
        guard let column, let content = column.window?.contentView else { return }
        if pill.superview !== content { content.addSubview(pill, positioned: .above, relativeTo: nil) }
        let slot = column.layoutResult.accessory ?? Self.noteSlot(in: column)
        let anchor = column.convert(slot, to: content)
        let height = (slot.height - Metrics.space2 * 2).rounded()
        let width = pill.fittingWidth(height: height)
        pill.frame = CGRect(x: anchor.maxX + Metrics.space2, y: anchor.midY - height / 2, width: width, height: height)
        pill.isHidden = false
    }

    /// Where the circle would sit: above the bottom band.
    private static func noteSlot(in column: SidebarRailColumnView) -> CGRect {
        let metrics = SidebarRailColumnView.metrics(width: column.bounds.width, topInset: column.topInset)
        let bottomTop = column.layoutResult.buttons.map(\.frame.minY).max() ?? column.bounds.height
        return CGRect(x: 0, y: bottomTop - metrics.buttonGap - metrics.buttonSize, width: column.bounds.width, height: metrics.buttonSize)
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menuTarget.reset()
        if case .ready = updater.indicatorPhase {
            menu.addItem(menuTarget.item(UpdateIndicatorPhase.installTitle) { [weak updater] in try? updater?.installAvailableUpdate() })
        }
        if let notes = updater.indicatorReleaseNotesURL {
            menu.addItem(menuTarget.item(UpdateIndicatorPhase.releaseNotesTitle) { NSWorkspace.shared.open(notes) })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let check: ActionID = "palette.checkForUpdates"
        menu.addItem(menuTarget.item(WindowRail.title(for: check, registry: registry)) { [weak registry] in
            _ = registry?.perform(check)
        })
        return menu
    }
}

/// Runs a menu item's closure.
@MainActor
private final class MenuTarget: NSObject {
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    func reset() { actions = [:] }

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        actions[ObjectIdentifier(item)] = action
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        actions[ObjectIdentifier(sender)]?()
    }
}
