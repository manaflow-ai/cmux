package import AppKit
package import CmuxNextActions
import CmuxNextDesign
package import CmuxNextInputCore

/// The action latency HUD (Debug menu > Toggle Action Latency HUD, DEV and NIGHTLY): a small
/// floating panel with the newest action runs, each with its perform-to-commit time, entrypoint and
/// id, the ones over the 10 ms budget in the danger color. Everyone who dogfoods sees a slow action
/// the moment it happens.
///
/// With an input feed it also lists the newest input events (Chrome's EventLatency,
/// cc/metrics/event_metrics.h): kind, target, OS event to presented frame, and the stage interval
/// that took the longest; the ones over one 120 Hz frame in the danger color.
///
/// It reads ``ActionBudgetMonitor/samples(everyRun:)`` and is a reader of the input feed
/// (`InputLatencyFeed.addReader(replaying:_:)`) only while shown; hidden (or closed with the title
/// bar button), it holds no reader, so the always-on paths stay ring writes. The panel never takes
/// the keys or activates the app.
@MainActor
package final class ActionLatencyHUD {
    /// Rows shown per section, newest first.
    package static let rowCount = 16
    /// An input row over this is in the danger color: one frame at 120 Hz, p04's key-to-frame target.
    package static let inputBudgetNanos: UInt64 = 8_333_333

    /// One input event as the HUD shows it.
    package struct InputRow: Sendable, Equatable {
        /// The event.
        package let slot: InputLatencySlot
        /// Its longest stage interval, read once when it arrives.
        package let dominant: InputLatencyDominantStage?

        package init(_ slot: InputLatencySlot) {
            self.slot = slot
            dominant = slot.dominantStage
        }
    }

    private let monitor: ActionBudgetMonitor
    private let inputFeed: (any InputLatencyFeed)?
    private var panel: NSPanel?
    private var label: NSTextField?
    private var closeObserver: PanelCloseObserver?
    private var watch: Task<Void, Never>?
    private var inputReader: InputLatencyReader?
    /// The runs shown, newest first (at most ``rowCount``).
    package private(set) var rows: [ActionTimingSample] = []
    /// The input events shown, newest first (at most ``rowCount``).
    package private(set) var inputRows: [InputRow] = []

    /// - Parameters:
    ///   - monitor: The app's per-action budget.
    ///   - inputs: Where closed input events come from; `nil` shows no input section.
    package init(monitor: ActionBudgetMonitor, inputs: (any InputLatencyFeed)? = nil) {
        self.monitor = monitor
        inputFeed = inputs
    }

    /// Whether the panel is on screen.
    package var isShown: Bool { panel?.isVisible == true }

    /// Shows the panel over `window`'s top-right corner, or hides it.
    package func toggle(over window: NSWindow?) {
        isShown ? hide() : show(over: window)
    }

    /// Shows the panel, filled with the ring's newest runs, and follows every new run (and every
    /// closed input; a new feed reader replays the newest ones first).
    package func show(over window: NSWindow?) {
        rows = monitor.recent(Self.rowCount)
        // The rows a hidden HUD kept are stale: the new feed reader's replay fills them.
        if inputReader == nil { inputRows = [] }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        render()
        if let frame = window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 48))
        }
        panel.orderFront(nil)
        if watch == nil {
            let runs = monitor.samples(everyRun: true)
            // task-owner: this HUD (cancelled in hide); event-driven (the monitor's stream).
            // main-hop-allow: Debug HUD shown on request: the monitor yields each run on main, and adding its row is the HUD's only work
            watch = Task { [weak self] in
                for await run in runs { self?.add(run) }
            }
        }
        if inputReader == nil, let inputFeed {
            // The feed calls the reader in the turn each input closes; hide removes it.
            inputReader = inputFeed.addReader(replaying: Self.rowCount) { [weak self] slot in self?.addInput(slot) }
        }
    }

    /// Hides the panel and stops reading runs and input events.
    package func hide() {
        watch?.cancel()
        watch = nil
        if let inputReader { inputFeed?.removeReader(inputReader) }
        inputReader = nil
        panel?.orderOut(nil)
    }

    /// The panel once shown (tests close it the way its title bar button does).
    package var window: NSWindow? { panel }

    /// Whether the HUD holds a reader on the monitor (tests: none while hidden).
    package var isReadingRuns: Bool { watch != nil }

    /// Whether the HUD holds a reader on the input feed (tests: none while hidden).
    package var isReadingInputs: Bool { inputReader != nil }

    /// Puts `run` first (the stream, or a test).
    package func add(_ run: ActionTimingSample) {
        rows.insert(run, at: 0)
        if rows.count > Self.rowCount { rows.removeLast(rows.count - Self.rowCount) }
        render()
    }

    /// Puts `slot` first (the feed's reader, or a test).
    package func addInput(_ slot: InputLatencySlot) {
        inputRows.insert(InputRow(slot), at: 0)
        if inputRows.count > Self.rowCount { inputRows.removeLast(inputRows.count - Self.rowCount) }
        render()
    }

    /// The panel's text: the header, then one line per run.
    package var text: NSAttributedString {
        let font = Typography.system(.monospacedDigit, size: TypeScale.caption)
        let budget = Int(monitor.budgetNanos / 1_000_000)
        let out = NSMutableAttributedString(string: Self.header(budget) + "\n",
                                            attributes: [.font: font, .foregroundColor: Palette.textSecondary])
        if rows.isEmpty {
            out.append(NSAttributedString(string: Self.empty, attributes: [.font: font, .foregroundColor: Palette.textTertiary]))
        }
        for run in rows {
            let over = run.isOver(budgetNanos: monitor.budgetNanos)
            let color: NSColor = over ? Palette.danger : run.outcome == .committed ? Palette.textPrimary : Palette.textTertiary
            let line = Self.row(String(format: "%6.1f", run.milliseconds), run.entrypoint.rawValue, run.id.rawValue)
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        if inputFeed != nil { appendInputs(to: out, font: font) }
        return out
    }

    /// The input section: its header, then one line per event.
    private func appendInputs(to out: NSMutableAttributedString, font: NSFont) {
        let budget = Double(Self.inputBudgetNanos) / 1_000_000
        out.append(NSAttributedString(string: "\n" + Self.inputHeader(budget) + "\n",
                                      attributes: [.font: font, .foregroundColor: Palette.textSecondary]))
        if inputRows.isEmpty {
            out.append(NSAttributedString(string: Self.inputEmpty, attributes: [.font: font, .foregroundColor: Palette.textTertiary]))
        }
        for input in inputRows {
            let total = input.slot.totalNanos
            let color: NSColor
            if let total {
                color = total > Self.inputBudgetNanos ? Palette.danger : Palette.textPrimary
            } else {
                color = Palette.textTertiary
            }
            let kind = Self.label(input.slot.kind)
            let target = Self.label(input.slot.target)
            let line = if let dominant = input.dominant {
                Self.inputRow(Self.milliseconds(total), kind, target, Self.label(dominant.from), Self.label(dominant.to),
                              Self.milliseconds(dominant.nanos))
            } else {
                Self.inputRowWithoutStages(Self.milliseconds(total), kind, target)
            }
            out.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
    }

    /// `nanos` the way the rows show milliseconds; a dash for an event that skipped an end.
    private static func milliseconds(_ nanos: UInt64?) -> String {
        guard let nanos else { return "     -" }
        return String(format: "%6.1f", Double(nanos) / 1_000_000)
    }

    private func render() {
        label?.attributedStringValue = text
        label?.sizeToFit()
        guard let panel, let label else { return }
        panel.setContentSize(NSSize(width: max(label.frame.width + 24, 320), height: label.frame.height + 16))
        label.setFrameOrigin(NSPoint(x: 12, y: 8))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.title = Self.title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false  // AppKit state restoration is off for every cmux window
        // The title bar's close button closes the panel without hide(): stop the readers there too.
        let closeObserver = PanelCloseObserver { [weak self] in self?.hide() }
        panel.delegate = closeObserver
        self.closeObserver = closeObserver
        let label = NSTextField(labelWithAttributedString: NSAttributedString())
        label.maximumNumberOfLines = 0
        panel.contentView?.addSubview(label)
        self.label = label
        return panel
    }

    // MARK: Strings (ActionLatencyHUD.xcstrings)

    private static var title: String {
        String(localized: "actionLatencyHUD.title", defaultValue: "Action Latency", table: "ActionLatencyHUD", bundle: .module)
    }

    private static func header(_ budget: Int) -> String {
        String(format: String(localized: "actionLatencyHUD.header", defaultValue: "Newest first, budget %d ms to commit",
                              table: "ActionLatencyHUD", bundle: .module), budget)
    }

    private static var empty: String {
        String(localized: "actionLatencyHUD.empty", defaultValue: "No actions yet", table: "ActionLatencyHUD", bundle: .module)
    }

    private static func row(_ milliseconds: String, _ entrypoint: String, _ id: String) -> String {
        String(format: String(localized: "actionLatencyHUD.row", defaultValue: "%1$@ ms  %2$@  %3$@",
                              table: "ActionLatencyHUD", bundle: .module), milliseconds, entrypoint, id)
    }

    private static func inputHeader(_ budget: Double) -> String {
        String(format: String(localized: "actionLatencyHUD.inputHeader", defaultValue: "Input, newest first, budget %.1f ms to frame",
                              table: "ActionLatencyHUD", bundle: .module), budget)
    }

    private static var inputEmpty: String {
        String(localized: "actionLatencyHUD.inputEmpty", defaultValue: "No input yet", table: "ActionLatencyHUD", bundle: .module)
    }

    private static func inputRow(_ milliseconds: String, _ kind: String, _ target: String, _ from: String, _ to: String,
                                 _ stageMilliseconds: String) -> String {
        String(format: String(localized: "actionLatencyHUD.inputRow", defaultValue: "%1$@ ms  %2$@  %3$@  longest %4$@ to %5$@ %6$@ ms",
                              table: "ActionLatencyHUD", bundle: .module),
               milliseconds, kind, target, from, to, stageMilliseconds)
    }

    private static func inputRowWithoutStages(_ milliseconds: String, _ kind: String, _ target: String) -> String {
        String(format: String(localized: "actionLatencyHUD.inputRowNoStages", defaultValue: "%1$@ ms  %2$@  %3$@",
                              table: "ActionLatencyHUD", bundle: .module), milliseconds, kind, target)
    }
}

/// Tells the HUD when the panel's title bar button closes it (the panel holds its delegate weakly).
@MainActor
private final class PanelCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
