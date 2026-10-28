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
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
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
            let picture = BackdropSelectionSetting().parse(root, diagnostics: &[]) 
            let shuffle = BackdropSelectionSetting.shuffle(root)
            return (picture, shuffle.map { max(1, $0.nextTurn(after: now(), calendar: calendar()).timeIntervalSince(now()) + 1) })
        }
        guard raw != "none" else { return (nil, nil) }
        let rotation = rotations?[id]?.stringValue.flatMap(BackdropRotation.init(rawValue:)) ?? .defaultRotation
        let shuffle: BackdropShuffle?
        if raw == BackdropSelectionSetting.dailyID { shuffle = BackdropShuffle(source: .paintings, rotation: rotation) }
        else if raw.hasPrefix(BackdropSelectionSetting.folderPrefix) {
            let path = String(raw.dropFirst(BackdropSelectionSetting.folderPrefix.count))
            shuffle = path.hasPrefix("/") ? BackdropShuffle(source: .folder(path), rotation: rotation) : nil
        } else { shuffle = nil }
        if let shuffle { return (shuffle.pick(on: now(), calendar: calendar), max(1, shuffle.nextTurn(after: now(), calendar: calendar).timeIntervalSince(now()) + 1)) }
        return (BackdropSelection(id: raw), nil)
    }
}
