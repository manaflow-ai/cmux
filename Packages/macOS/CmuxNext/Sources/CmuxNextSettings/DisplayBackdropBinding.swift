public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups

/// Applies a display background between the app and room scopes. Explicit window and workspace
/// choices still win. The window owner calls ``stop()`` when it tears down.
@MainActor
public final class DisplayBackdropBinding {
    private let scope: ThemeScope
    private let displayScope: ThemeScope
    private let inheritedScope: ThemeScope
    private let window: NSWindow
    private let center: NotificationCenter
    private let displayID: () -> String?
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let timer = DemandTimer(owner: "display-backdrop")
    private var observers: [NSObjectProtocol] = []
    private var root: JSONValue = [:]
    private var stopped = false

    public init(window: NSWindow, scope: ThemeScope, center: NotificationCenter = .default,
                displayID: @escaping () -> String?, now: @escaping () -> Date = Date.init,
                calendar: @escaping () -> Calendar = { .current }) {
        self.window = window; self.scope = scope; self.center = center; self.displayID = displayID; self.now = now; self.calendar = calendar
        inheritedScope = scope.parent ?? .app
        displayScope = ThemeScope(level: .room, parent: inheritedScope)
        scope.setParent(displayScope)
        observers.append(center.addObserver(forName: nil, object: nil, queue: .main) { [weak self, weak window] note in
            guard note.name == NSWindow.didChangeScreenNotification || note.name == .NSSystemClockDidChange || note.name == .NSCalendarDayChanged || note.name == .NSSystemTimeZoneDidChange,
                  note.name != NSWindow.didChangeScreenNotification || note.object as AnyObject? === window else { return }
            Task { @MainActor [weak self] in self?.refresh() }
        })
    }

    public func apply(_ root: JSONValue) { self.root = root; refresh() }

    public func stop() {
        stopped = true
        timer.cancel()
        observers.forEach(center.removeObserver)
        observers.removeAll()
        displayScope.pinBackdrop(.inherit)
        if scope.parent === displayScope { scope.setParent(inheritedScope) }
    }

    private func refresh() {
        guard !stopped else { return }
        timer.cancel()
        let result = selection()
        displayScope.pinBackdrop(result.pin)
        if let wait = result.wait { timer.schedule(after: .seconds(wait)) { @MainActor [weak self] in self?.refresh() } }
    }

    private func selection() -> (pin: BackdropPin, wait: TimeInterval?) {
        let id = displayID()
        let values = root.value(at: ["appearance", "displayBackgrounds"])?.objectValue
        let rotations = root.value(at: ["appearance", "displayBackgroundRotations"])?.objectValue
        guard let id, let raw = values?[id]?.stringValue else {
            return (.inherit, nil)
        }
        guard raw != "none" else { return (.none, nil) }
        let rotation = rotations?[id]?.stringValue.flatMap(BackdropRotation.init(rawValue:)) ?? .defaultRotation
        let shuffle: BackdropShuffle?
        if raw == BackdropSelectionSetting.dailyID { shuffle = BackdropShuffle(source: .paintings, rotation: rotation) }
        else if raw.hasPrefix(BackdropSelectionSetting.folderPrefix) {
            shuffle = BackdropSelectionSetting.folderPath(raw).map { BackdropShuffle(source: .folder($0), rotation: rotation) }
        } else { shuffle = nil }
        if let shuffle {
            let turn = shuffle.turn(at: now(), calendar: calendar())
            return (turn.picture.map(BackdropPin.selection) ?? .none, turn.wait)
        }
        return (BackdropSelection(id: raw).map(BackdropPin.selection) ?? .inherit, nil)
    }
}
