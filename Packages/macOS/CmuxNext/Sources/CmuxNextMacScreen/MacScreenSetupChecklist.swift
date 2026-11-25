import AppKit
import CmuxNextDesign

/// The steps of a Set Up cmux or Start cmux run (``MacScreenDeviceRun``), under a Mac's row on the
/// Screen Sharing page and in the offline card: a heading that says where the run stands, then one
/// line per step the CLI reported, in the Add Machine checklist's glyph language (done, warning,
/// failed, skipped), each with its detail and, for a warning or failure, what a person can do. The
/// words of a step are the CLI's; only the heading is the app's.
@MainActor
enum MacScreenSetupChecklist {
    static func startTitle(_ name: String) -> String {
        String(format: L.t("macScreen.setup.start", "Start cmux on %@"), name)
    }

    /// The heading of a run: running, done, failed, or this cmux too old for the verb.
    static func heading(_ run: MacScreenDeviceRun, name: String) -> String {
        let start = run.verb == .start
        switch run.phase {
        case .running:
            return String(format: start ? L.t("macScreen.setup.starting", "Starting cmux on %@…")
                : L.t("macScreen.setup.settingUp", "Setting up cmux on %@…"), name)
        case .succeeded:
            return String(format: start ? L.t("macScreen.setup.started", "cmux is running on %@.")
                : L.t("macScreen.setup.setUpDone", "cmux is set up on %@."), name)
        case .failed:
            return String(format: start ? L.t("macScreen.setup.startFailed", "Couldn’t start cmux on %@.")
                : L.t("macScreen.setup.setUpFailed", "Couldn’t set up cmux on %@."), name)
        case .needsNewerCmux:
            return L.t("macScreen.setup.needsNewer", "This version of cmux can’t do this yet. Update cmux on this Mac, then try again.")
        }
    }

    /// A step's glyph and ink, as the Add Machine checklist tells them apart.
    static func glyph(_ state: MacScreenDeviceStep.State) -> (symbol: String, ink: KeyPath<MacScreenColors, NSColor>) {
        switch state {
        case .ok, .changed: ("checkmark.circle.fill", \.success)
        case .warn: ("exclamationmark.triangle.fill", \.attention)
        case .fail: ("xmark.octagon.fill", \.danger)
        case .skip: ("minus.circle", \.tertiary)
        }
    }

    /// The checklist; `done` hides a finished run (its Done button).
    static func make(_ run: MacScreenDeviceRun, name: String, id: String, done: @escaping () -> Void) -> NSView {
        let column = MacScreenStack.make(.vertical, spacing: 6, alignment: .leading)
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityIdentifier(id)
        column.setAccessibilityLabel(heading(run, name: name))
        var head: [NSView] = []
        switch run.phase {
        case .running:
            let spinner = StatusIndicatorView.spinner()
            spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: 14),
                spinner.heightAnchor.constraint(equalToConstant: 14),
            ])
            spinner.spin(true)
            head.append(spinner)
        case .succeeded:
            head.append(MacScreenGlyph("checkmark.circle.fill", font: MacScreenType.body, ink: \.success))
        case .failed:
            head.append(MacScreenGlyph("xmark.octagon.fill", font: MacScreenType.body, ink: \.danger))
        case .needsNewerCmux:
            head.append(MacScreenGlyph("exclamationmark.triangle.fill", font: MacScreenType.body, ink: \.attention))
        }
        let title = MacScreenText(heading(run, name: name), font: MacScreenType.emphasized, wraps: true)
        head.append(title)
        if !run.isRunning {
            head.append(MacScreenSpacer())
            head.append(MacScreenButton(L.t("macScreen.setup.done", "Done"), compact: true, id: "\(id).done", action: done))
        }
        let heading = MacScreenStack.make(.horizontal, spacing: 6, alignment: .centerY, head)
        MacScreenStack.addFullWidth(heading, to: column)
        if case let .failed(message) = run.phase, !message.isEmpty {
            MacScreenStack.addFullWidth(MacScreenText(message, font: MacScreenType.caption, ink: \.secondary, wraps: true), to: column)
        }
        for step in run.steps {
            MacScreenStack.addFullWidth(stepLine(step), to: column)
        }
        return column
    }

    private static func stepLine(_ step: MacScreenDeviceStep) -> NSView {
        let (symbol, ink) = glyph(step.state)
        let mark = MacScreenGlyph(symbol, font: MacScreenType.caption, ink: ink, width: 14)
        let text = MacScreenStack.make(.vertical, spacing: 1, alignment: .leading)
        let line = step.detail.isEmpty ? step.step : "\(step.step) · \(step.detail)"
        MacScreenStack.addFullWidth(MacScreenText(line, font: MacScreenType.caption, ink: step.state == .skip ? \.tertiary : \.primary, wraps: true),
                                    to: text)
        if let fix = step.fix, step.state == .warn || step.state == .fail {
            MacScreenStack.addFullWidth(MacScreenText(fix, font: MacScreenType.caption, ink: \.secondary, wraps: true), to: text)
        }
        let row = MacScreenStack.make(.horizontal, spacing: 6, alignment: .top, [mark, text])
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel([step.step, step.detail, step.fix ?? ""].filter { !$0.isEmpty }.joined(separator: ". "))
        return row
    }
}
