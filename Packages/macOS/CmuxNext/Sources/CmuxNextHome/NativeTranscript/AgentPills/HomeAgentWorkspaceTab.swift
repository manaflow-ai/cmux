#if DEBUG
import AppKit
import CmuxNextDesign

/// DEBUG ONLY: variant B of the Agent Messages Playground, "a workspace inside a tab" (user 2026-11-03,
/// msg 19960): the right pane's tab holds the agent's whole workspace, its own pane tabs (Agent, Terminal)
/// over its chat beside its terminal, with Go to workspace to pop it out. A mock; DEV-only English.
@MainActor
final class HomeAgentWorkspaceTab: NSView {
    init(agent: HomeAgentPlaygroundAgent, actions: HomeAgentChatView.Actions) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "Workspace · \(agent.title)")
        title.font = Typography.system(size: TypeScale.detail, weight: TypeScale.emphasis)
        title.lineBreakMode = .byTruncatingTail
        let tabs = NSSegmentedControl(labels: ["Agent", "Terminal"], trackingMode: .selectOne, target: nil, action: nil)
        tabs.controlSize = .small
        tabs.selectedSegment = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, tabs, spacer])
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        // The workspace's own chat keeps Go to workspace (it moves this tab's workspace into the sidebar).
        let chat = HomeAgentChatView(agent: agent, actions: actions)
        let terminal = NSTextView()
        terminal.isEditable = false
        terminal.drawsBackground = true
        terminal.backgroundColor = NSColor(white: 0.09, alpha: 1)
        terminal.textColor = NSColor(white: 0.85, alpha: 1)
        terminal.font = Typography.system(.monospaced, size: TypeScale.caption)
        terminal.textContainerInset = NSSize(width: 8, height: 8)
        terminal.string = (["$ cmux-ci status"] + agent.steps.map { "› " + $0 } + ["$ █"]).joined(separator: "\n")
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(chat)
        split.addArrangedSubview(terminal)
        for view in [header, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.widthAnchor.constraint(equalTo: chat.widthAnchor, multiplier: 0.7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
#endif
