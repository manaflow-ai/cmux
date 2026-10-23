public import AppKit
import CmuxNextWakeups
import CoreGraphics

/// The app's file picker, made ahead of the click: Home's "+" and an agent composer's
/// + > Attach files or images (a page's `<input type="file">`) take this panel.
///
/// `NSOpenPanel()` costs 105 to 120 ms on the main thread, about 300 ms for the process's
/// first one (frameworks and the panel service load), before `beginSheetModal` adds its own
/// 270 ms. Bench on a capture mini (macOS 26.3.1, a bare app, 2026-10-21): a new panel per
/// click first shows its sheet 830 ms after the click in a fresh process and 160 ms after it
/// later; the panel made ahead shows it after 95 ms, then 45 to 65 ms. One panel is made while
/// the person is idle and reused. The warm-up still costs that main-thread time once, at a
/// pause or while cmux is in the background.
@MainActor
public final class MadeAheadOpenPanel {
    public static let shared = MadeAheadOpenPanel()

    private var made: NSOpenPanel?
    private var madeDefaults: OpenPanelDefaults?
    /// Whether the panel was made ahead of a click.
    public var isMade: Bool { made != nil }
    /// The warm-up checks run so far, and whether another is pending.
    public private(set) var warmChecks = 0
    public var isWarming: Bool { timer.isScheduled }
    /// Whether the warm-up gave up for this launch (no panel service, or no panel came back).
    public private(set) var stoppedWarming = false

    private let world: MadeAheadOpenPanelWorld
    private let timer: DemandTimer

    public convenience init() {
        self.init(world: .live)
    }

    init(world: MadeAheadOpenPanelWorld) {
        self.world = world
        timer = DemandTimer(owner: "openPanel.madeAhead.warm", clock: world.clock)
    }

    /// The panel made ahead when it is free (no sheet or window shows it), else a new one (it
    /// shows on another window). Either comes as a new panel would: one file, no folders, every
    /// type, the system's prompt and no message; the caller sets what it needs.
    public func panel() -> NSOpenPanel {
        let free = made.flatMap { $0.isVisible || $0.sheetParent != nil ? nil : $0 }
        guard let panel = free else {
            let panel = NSOpenPanel()
            if made == nil { keep(panel) }
            return panel
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = []
        madeDefaults?.apply(to: panel)
        return panel
    }

    /// Makes the panel once the person has paused (no input for a second), so its cost never
    /// lands on a keystroke or the click itself. Bounded: after ten busy checks it waits for the
    /// click. A view that offers the picker calls this when it reaches a window.
    public func warmWhenIdle() {
        guard made == nil, !timer.isScheduled else { return }
        check(after: world.firstCheck, triesLeft: 10)
    }

    /// Keeps `panel` for later clicks, unless its view service never answered (no prompt): then the next
    /// click makes a new one, and the launch goes on.
    private func keep(_ panel: NSOpenPanel) {
        guard let defaults = OpenPanelDefaults(of: panel) else { return }
        made = panel
        madeDefaults = defaults
    }

    private func check(after delay: Duration, triesLeft: Int) {
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self else { return }
            warmChecks += 1
            guard made == nil else { return }
            switch world.gate() {
            case .never:
                return
            case .busy:
                if triesLeft > 1 { check(after: world.retry, triesLeft: triesLeft - 1) }
                return
            case .go:
                if let panel = world.makePanel() { keep(panel) }
            }
        }
    }
}
