#if DEBUG
public import AppKit
public import MessagesLabHome
import CmuxNextDesign

/// DEBUG ONLY: Debug > Agent Messages Playground (user 2026-11-02, msg 19613: "i want playground in swift,
/// not html"). One window with the real Home transcript over the mock owner (``HomeNativeFixture``) and a
/// bar that switches, live, the agent-message header variant (``HomeAgentFoldStyle``), collapsed or
/// expanded, in the Chief's own chat or a team chat (where the Chief's avatar and name draw), light or dark.
///
/// The pill styles (user 2026-11-03, msg 19960) draw one ChatGPT-style pill per agent; a click on a pill
/// opens that agent's chat the way the Open picker says (``HomeAgentOpenStyle``: a right pane with tabs, a
/// workspace in a tab, a peek, ⌘-click to the workspace, inline, a pushed page or a floating window).
///
/// The variant is one row provider for the process while the window is open; closing the window puts
/// the shipped look back. The labels are DEV-only English. ⌘[ and ⌘] step through the variants.
@MainActor
public final class HomeAgentMessagePlayground: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.home.agentMessagePlayground")

    private let window: NSWindow
    private let fixture: HomeNativeFixture
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fold = NSSegmentedControl(labels: ["Collapsed", "Expanded"], trackingMode: .selectOne, target: nil, action: nil)
    private let chat = NSSegmentedControl(labels: ["Chief chat", "Team chat"], trackingMode: .selectOne, target: nil, action: nil)
    private let look = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let split = NSSplitView()
    private let side = HomeAgentSidePane()
    private var pushed: HomeAgentChatView?
    private var floating: NSPanel?
    private var peek: NSView?
    private var notice: String?
    private var state: (style: HomeAgentFoldStyle, expanded: Bool, team: Bool)
    private var open: HomeAgentOpenStyle = .rightPane

    /// Shows the playground (one window: a second call brings it front), switched to the given variant,
    /// folds, chat, open behavior and look; with `peer` it then opens that agent as a click on its pill does.
    /// nil keeps what it shows (a new window: the shipped look, collapsed, the Chief's chat, the right pane).
    public static func show(style: Int? = nil, expanded: Bool? = nil, team: Bool? = nil, open: Int? = nil,
                            peer: String? = nil, dark: Bool? = nil, command: Bool = false) {
        let shown = NSApp.windows.first { $0.identifier == identifier }
        let playground = (shown?.contentView as? HomeAgentMessagePlaygroundView)?.owner
            ?? HomeAgentMessagePlayground(style: .current, expanded: false, team: false)
        let current = playground.state
        if let open, let behavior = HomeAgentOpenStyle(rawValue: open) { playground.setOpen(behavior) }
        if let dark { playground.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        playground.select(style.flatMap(HomeAgentFoldStyle.init(rawValue:)) ?? current.style,
                          expanded: expanded ?? current.expanded, team: team ?? current.team)
        playground.window.makeKeyAndOrderFront(nil)
        if let peer { _ = playground.pillClicked(peer, command: command) }
    }

    private init(style: HomeAgentFoldStyle, expanded: Bool, team: Bool) {
        state = (style, expanded, team)
        fixture = HomeNativeFixture(playground: state)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        fixture.onPill = { [weak self] peer, _ in
            self?.pillClicked(peer, command: NSEvent.modifierFlags.contains(.command))
        }
        window.identifier = Self.identifier
        window.title = "Agent Messages Playground"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = HomeAgentMessagePlaygroundView()
        content.owner = self
        window.contentView = content
        layout(in: content)
        window.center()
        sync()
    }

    private func layout(in content: NSView) {
        for style in HomeAgentFoldStyle.allCases { picker.addItem(withTitle: "\(style.rawValue). \(style.title)") }
        for behavior in HomeAgentOpenStyle.allCases { openPicker.addItem(withTitle: behavior.title) }
        for (control, action) in [(picker, #selector(pickerChanged)), (openPicker, #selector(openChanged))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }
        for (control, action) in [(fold, #selector(foldChanged)), (chat, #selector(chatChanged)), (look, #selector(lookChanged))] {
            control.target = self
            control.action = action
        }
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 2
        let controls = NSStackView(views: [picker, fold, chat])
        controls.spacing = 12
        let openRow = NSStackView(views: [NSTextField(labelWithString: "Click on a pill:"), openPicker, look])
        openRow.spacing = 12
        let bar = NSStackView(views: [controls, openRow, caption])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(fixture.container)
        split.addArrangedSubview(side)
        side.isHidden = true
        side.emptied = { [weak self] in self?.hideSide() }
        for view in [bar, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            fixture.container.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            side.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
    }

    /// Switches the playground to `style`, folds and chat, live.
    func select(_ style: HomeAgentFoldStyle, expanded: Bool, team: Bool) {
        state = (style, expanded, team)
        fixture.debugPlayground(style: style, expanded: expanded, team: team)
        sync()
    }

    /// One variant before or after the shown one (← and →).
    func step(_ offset: Int) {
        let all = HomeAgentFoldStyle.allCases
        guard let index = all.firstIndex(of: state.style) else { return }
        let next = (index + offset + all.count) % all.count
        guard let style = all.dropFirst(next).first else { return }
        select(style, expanded: state.expanded, team: state.team)
    }

    private func sync() {
        picker.selectItem(at: state.style.rawValue)
        openPicker.selectItem(at: open.rawValue)
        fold.selectedSegment = state.expanded ? 1 : 0
        chat.selectedSegment = state.team ? 1 : 0
        look.selectedSegment = window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            || (window.appearance == nil && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ? 1 : 0
        let pills = state.style.isPill
        caption.stringValue = notice ?? (pills ? "\(state.style.caption) \(open.caption)" : state.style.caption)
    }

    // MARK: Opening an agent

    /// What a click on `peer`'s pill does in the chosen open behavior; true: the click is taken.
    @discardableResult
    func pillClicked(_ peer: String, command: Bool) -> Bool {
        let agent = HomeAgentPlaygroundAgent.named(peer)
        notice = nil
        switch open {
        case .rightPane: openSide(agent, workspace: false)
        case .workspaceTab: openSide(agent, workspace: true)
        case .peek: showPeek(agent)
        case .commandClick: if command { goToWorkspace(agent) } else { openSide(agent, workspace: false) }
        case .inline:
            select(state.style, expanded: !state.expanded, team: state.team)
        case .replace: push(agent)
        case .floating: float(agent)
        }
        sync()
        return true
    }

    private func actions(for agent: HomeAgentPlaygroundAgent, open: (() -> Void)? = nil, back: (() -> Void)? = nil,
                         close: (() -> Void)? = nil) -> HomeAgentChatView.Actions {
        HomeAgentChatView.Actions(
            goToWorkspace: { [weak self] in self?.goToWorkspace(agent) }, open: open, back: back, close: close,
            sent: { [weak self] text in
                self?.notice = "The Chief sees it: \"You → \(agent.peer): \(text)\" goes into the Chief's next turn."
                self?.sync()
            })
    }

    private func openSide(_ agent: HomeAgentPlaygroundAgent, workspace: Bool) {
        let actions = actions(for: agent)
        side.open(agent.peer, title: agent.title) {
            workspace ? HomeAgentWorkspaceTab(agent: agent, actions: actions) : HomeAgentChatView(agent: agent, actions: actions)
        }
        guard side.isHidden else { return }
        side.isHidden = false
        split.adjustSubviews()
        split.setPosition(max(420, split.bounds.width - (workspace ? 620 : 420)), ofDividerAt: 0)
    }

    private func hideSide() {
        side.isHidden = true
        split.adjustSubviews()
    }

    private func showPeek(_ agent: HomeAgentPlaygroundAgent) {
        peek?.removeFromSuperview()
        guard let content = window.contentView else { return }
        let chat = HomeAgentChatView(agent: agent, compact: true, actions: actions(
            for: agent,
            open: { [weak self] in
                self?.closePeek()
                self?.openSide(agent, workspace: false)
            },
            close: { [weak self] in self?.closePeek() }))
        chat.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
        let surface = Glass.makeOverlayPanel(content: chat, cornerRadius: Metrics.surfaceCornerRadius)
        surface.translatesAutoresizingMaskIntoConstraints = true
        let mouse = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = content.bounds.contains(mouse) ? mouse : NSPoint(x: 200, y: content.bounds.midY)
        let origin = NSPoint(x: min(anchor.x + 12, content.bounds.maxX - 392), y: max(12, min(anchor.y - 150, content.bounds.maxY - 312)))
        surface.frame = NSRect(origin: origin, size: chat.frame.size)
        chat.autoresizingMask = [.width, .height]
        content.addSubview(surface)
        peek = surface
    }

    private func closePeek() {
        peek?.removeFromSuperview()
        peek = nil
    }

    private func push(_ agent: HomeAgentPlaygroundAgent) {
        pushed?.removeFromSuperview()
        let view = HomeAgentChatView(agent: agent, actions: actions(for: agent, back: { [weak self] in self?.popPushed() }))
        // The agent's chat takes the Chief chat's place in the split (a pushed page); back puts it back.
        fixture.container.isHidden = true
        split.insertArrangedSubview(view, at: 0)
        pushed = view
    }

    private func popPushed() {
        pushed?.removeFromSuperview()
        pushed = nil
        fixture.container.isHidden = false
        split.adjustSubviews()
    }

    private func float(_ agent: HomeAgentPlaygroundAgent) {
        let panel = floating ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = agent.title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.contentView = HomeAgentChatView(agent: agent, actions: actions(for: agent))
        let frame = window.frame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 420, y: frame.maxY - 140))
        panel.orderFront(nil)
        floating = panel
    }

    /// Go to workspace: in the app it selects the agent's workspace in the sidebar (cmux://workspace/…);
    /// the playground has no workspace, so it says where it would go.
    private func goToWorkspace(_ agent: HomeAgentPlaygroundAgent) {
        notice = "Go to workspace: switches the window to the \"\(agent.title)\" workspace (\(agent.peer)), its chat focused."
        sync()
    }

    /// Closes what the open behavior showed (the behavior changed, or the window closes).
    private func closeOpened() {
        side.closeAll()
        closePeek()
        floating?.close()
        popPushed()
    }

    private func setOpen(_ behavior: HomeAgentOpenStyle) {
        guard behavior != open else { return }
        open = behavior
        notice = nil
        closeOpened()
        sync()
    }

    // MARK: Controls

    @objc private func pickerChanged() {
        guard let style = HomeAgentFoldStyle(rawValue: picker.indexOfSelectedItem) else { return }
        select(style, expanded: state.expanded, team: state.team)
    }

    @objc private func openChanged() {
        guard let behavior = HomeAgentOpenStyle(rawValue: openPicker.indexOfSelectedItem) else { return }
        setOpen(behavior)
    }

    @objc private func foldChanged() { select(state.style, expanded: fold.selectedSegment == 1, team: state.team) }

    @objc private func chatChanged() { select(state.style, expanded: state.expanded, team: chat.selectedSegment == 1) }

    @objc private func lookChanged() {
        window.appearance = NSAppearance(named: look.selectedSegment == 1 ? .darkAqua : .aqua)
        floating?.appearance = window.appearance
    }

    public func windowWillClose(_ notification: Notification) {
        // The shipped look again for every Home view, then the playground lets go of its window and fixture.
        closeOpened()
        fixture.debugPlayground(style: .current, expanded: state.expanded, team: state.team)
        fixture.close()
        (window.contentView as? HomeAgentMessagePlaygroundView)?.owner = nil
    }
}
#endif
