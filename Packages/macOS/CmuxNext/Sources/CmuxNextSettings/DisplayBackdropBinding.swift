public import AppKit
public import CmuxNextDesign
import CmuxNextWakeups

/// Applies an optional display-specific background while retaining the app default when absent.
@MainActor
public final class DisplayBackdropBinding {
    private let scope: ThemeScope
    private let window: NSWindow
    private let center: NotificationCenter
    private let displayID: () -> String?
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let timer = DemandTimer(owner: "display-backdrop")
    private var observers: [NSObjectProtocol] = []
    private var root: JSONValue = [:]

    public init(window: NSWindow, scope: ThemeScope, center: NotificationCenter = .default,
                displayID: @escaping () -> String?, now: @escaping () -> Date = Date.init,
                calendar: @escaping () -> Calendar = { .current }) {
        self.window = window; self.scope = scope; self.center = center; self.displayID = displayID; self.now = now; self.calendar = calendar
        observers.append(center.addObserver(forName: nil, object: nil, queue: .main) { [weak self, weak window] note in
            guard note.name == NSWindow.didChangeScreenNotification || note.name == .NSSystemClockDidChange || note.name == .NSCalendarDayChanged || note.name == .NSSystemTimeZoneDidChange,
                  note.name != NSWindow.didChangeScreenNotification || note.object as AnyObject? === window else { return }
            self?.refresh()
        })
    }

    public func apply(_ root: JSONValue) { self.root = root; refresh() }

    public func stop() {
        timer.cancel()
        observers.forEach(center.removeObserver)
        observers.removeAll()
        scope.setBackdropSelection(nil)
    }

    private func refresh() {
        timer.cancel()
        let result = selection()
        scope.setBackdropSelection(result.picture)
        if let wait = result.wait { timer.schedule(after: .seconds(wait)) { @MainActor [weak self] in self?.refresh() } }
    }

    private func selection() -> (picture: BackdropSelection?, wait: TimeInterval?) {
        let id = displayID()
        let values = root.value(at: ["appearance", "displayBackgrounds"])?.objectValue
        let rotations = root.value(at: ["appearance", "displayBackgroundRotations"])?.objectValue
        guard let id, let raw = values?[id]?.stringValue else {
            var diagnostics: [SettingsDiagnostic] = []
            let picture = BackdropSelectionSetting().parse(root, diagnostics: &diagnostics)
            let shuffle = BackdropSelectionSetting.shuffle(root)
            return (picture, shuffle.map { $0.turn(at: now(), calendar: calendar()).wait })
        }
        guard raw != "none" else { return (nil, nil) }
        let rotation = rotations?[id]?.stringValue.flatMap(BackdropRotation.init(rawValue:)) ?? .defaultRotation
        let shuffle: BackdropShuffle?
        if raw == BackdropSelectionSetting.dailyID { shuffle = BackdropShuffle(source: .paintings, rotation: rotation) }
        else if raw.hasPrefix(BackdropSelectionSetting.folderPrefix) {
            let path = String(raw.dropFirst(BackdropSelectionSetting.folderPrefix.count))
            shuffle = path.hasPrefix("/") ? BackdropShuffle(source: .folder(path), rotation: rotation) : nil
        } else { shuffle = nil }
        if let shuffle { return shuffle.turn(at: now(), calendar: calendar) }
        return (BackdropSelection(id: raw), nil)
    }
}
