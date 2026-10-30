import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// The Chief Settings card's Automations block (issue 25573): the tasks the person asked the
/// Chief to run on a schedule or when an event happens (`chief.automation.list`), each with what
/// starts it, its next run or that it is paused, and Pause or
/// Resume and Delete (`chief.automation.update` through `onAction`). The Chief makes them in
/// chat with its `automation` tool; this block only shows and changes them.
@MainActor
final class HomeChiefAutomationRows: NSStackView {
    /// Pauses, resumes or deletes automation `id`; the card sends it to the brain.
    var onAction: (_ id: String, _ action: ChiefAutomationAction) -> Void = { _, _ in }
    /// The automations shown, oldest first.
    private(set) var shown: [ChiefAutomation] = []
    /// What each row's buttons do, by button.
    private var actions: [ObjectIdentifier: (id: String, action: ChiefAutomationAction)] = [:]
    private let width: CGFloat

    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space3
        setAccessibilityIdentifier("cmux.home.chief.automations")
        show([])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `automations` (the brain's list), or how to make one when there is none.
    func show(_ automations: [ChiefAutomation]) {
        shown = automations
        actions = [:]
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !automations.isEmpty else {
            let empty = HomeChiefSettingsView.footnote(HomeEngineStrings.automationsEmpty)
            empty.preferredMaxLayoutWidth = width
            add(empty)
            return
        }
        for automation in automations { add(row(automation)) }
    }

    /// One automation: its name, what starts it and when it runs next, then its actions.
    private func row(_ automation: ChiefAutomation) -> NSView {
        let name = ThemedLabel(labelWithString: automation.name)
        name.font = Typography.body
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = automation.prompt
        let detail = ThemedLabel(wrappingLabelWithString: Self.detail(automation))
        detail.font = Typography.caption
        detail.ink = .secondary
        detail.preferredMaxLayoutWidth = width
        var views: [NSView] = [name, detail]
        let toggle = button(automation.paused ? HomeEngineStrings.automationResume : HomeEngineStrings.automationPause,
                            id: automation.id, action: automation.paused ? .resume : .pause)
        let delete = button(HomeEngineStrings.automationDelete, id: automation.id, action: .delete)
        delete.ink = .danger
        let buttons = NSStackView(views: [toggle, delete])
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.space3
        views.append(buttons)
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space1
        column.setAccessibilityElement(true)
        column.setAccessibilityRole(.group)
        column.setAccessibilityLabel(automation.name)
        column.setAccessibilityIdentifier("cmux.home.chief.automation.\(automation.id)")
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return column
    }

    private func button(_ title: String, id: String, action: ChiefAutomationAction) -> HomeChiefLinkButton {
        let button = HomeChiefLinkButton(title: title, target: self, action: #selector(clicked(_:)))
        button.setAccessibilityIdentifier("cmux.home.chief.automation.\(id).\(action.rawValue)")
        actions[ObjectIdentifier(button)] = (id, action)
        return button
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let (id, action) = actions[ObjectIdentifier(sender)] else { return }
        onAction(id, action)
    }

    private func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    /// What starts `automation`, then that it is paused or when it runs next: "Schedule: 0 9 * * * ·
    /// Next: Oct 27, 2026 at 9:00 AM".
    nonisolated static func detail(_ automation: ChiefAutomation, locale: Locale = .current,
                                   timeZone: TimeZone = .current) -> String {
        var parts = [trigger(automation.trigger)]
        if automation.paused {
            parts.append(HomeEngineStrings.automationPaused)
        } else if let next = automation.nextMs {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
            style.timeZone = timeZone
            parts.append(String(format: HomeEngineStrings.automationNextFormat,
                                Date(timeIntervalSince1970: next / 1000).formatted(style)))
        }
        return parts.joined(separator: " · ")
    }

    /// What starts an automation, as the person reads it.
    nonisolated static func trigger(_ trigger: ChiefAutomation.Trigger) -> String {
        switch trigger {
        case .schedule(let cron): String(format: HomeEngineStrings.automationScheduleFormat, cron)
        case .agentDone(nil): HomeEngineStrings.automationAgentDone
        case .agentDone(let matches?): String(format: HomeEngineStrings.automationAgentDoneMatchingFormat, matches)
        case .other(let type): type
        }
    }
}
