package import AppKit
package import CmuxNextActions
import CmuxNextDesign

/// The action latency HUD (Debug menu > Toggle Action Latency HUD, DEV and NIGHTLY): a small
/// floating panel with the newest action runs, each with its perform-to-commit time, entrypoint and
/// id, the ones over the 10 ms budget in the danger color. Everyone who dogfoods sees a slow action
/// the moment it happens.
///
/// It reads ``ActionBudgetMonitor/samples(everyRun:)`` only while shown; hidden, it holds no reader,
/// so the monitor's always-on path stays a ring write. The panel never takes the keys or activates
/// the app.
@MainActor
package final class ActionLatencyHUD {
    /// Rows shown, newest first.
    package static let rowCount = 16

    private let monitor: ActionBudgetMonitor
    private var panel: NSPanel?
    private var label: NSTextField?
    private var watch: Task<Void, Never>?
    /// The runs shown, newest first (at most ``rowCount``).
    package private(set) var rows: [ActionTimingSample] = []

    /// - Parameter monitor: The app's per-action budget.
    package init(monitor: ActionBudgetMonitor) {
        self.monitor = monitor
    }

    /// Whether the panel is on screen.
    package var isShown: Bool { panel?.isVisible == true }

    /// Shows the panel over `window`'s top-right corner, or hides it.
    package func toggle(over window: NSWindow?) {
        isShown ? hide() : show(over: window)
    }

    /// Shows the panel, filled with the ring's newest runs, and follows every new run.
    package func show(over window: NSWindow?) {
        rows = monitor.recent(Self.rowCount)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        render()
        if let frame = window?.frame {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 48))
        }
        panel.orderFront(nil)
        guard watch == nil else { return }
        let runs = monitor.samples(everyRun: true)
        // task-owner: this HUD (cancelled in hide); event-driven (the monitor's stream).
        watch = Task { [weak self] in
            for await run in runs { self?.add(run) }
        }
    }

    /// Hides the panel and stops reading runs.
    package func hide() {
        watch?.cancel()
        watch = nil
        panel?.orderOut(nil)
    }

    /// Puts `run` first (the stream, or a test).
    package func add(_ run: ActionTimingSample) {
        rows.insert(run, at: 0)
        if rows.count > Self.rowCount { rows.removeLast(rows.count - Self.rowCount) }
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
        return out
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
}
