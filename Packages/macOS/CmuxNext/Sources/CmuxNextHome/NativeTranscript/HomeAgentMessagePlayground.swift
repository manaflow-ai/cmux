#if DEBUG
public import AppKit
public import MessagesLabHome
import CmuxNextDesign

/// DEBUG ONLY: Debug > Agent Messages Playground (user 2026-11-02, msg 19613: "i want playground in swift,
/// not html"). One window with the real Home transcript over the mock owner (``HomeNativeFixture``) and a
/// bar that switches, live, the agent-message header variant (``HomeAgentFoldStyle``), collapsed or
/// expanded, in the Chief's own chat or a team chat (where the Chief's avatar and name draw), light or dark.
///
/// The pill styles (user 2026-11-03, msg 19960) draw one ChatGPT-style pill per agent; in the app a click on
/// a pill opens that agent's workspace (Home never splits, user 2026-11-07, msg 23836); here it says where.
///
/// The variant is one row provider for the process while the window is open; closing the window puts
/// the shipped look back. The labels are DEV-only English. ⌘[ and ⌘] step through the variants.
@MainActor
public final class HomeAgentMessagePlayground: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.home.agentMessagePlayground")

    private let window: NSWindow
    private let fixture: HomeNativeFixture
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fold = NSSegmentedControl(labels: ["Collapsed", "Expanded"], trackingMode: .selectOne, target: nil, action: nil)
    private let chat = NSSegmentedControl(labels: ["Chief chat", "Team chat"], trackingMode: .selectOne, target: nil, action: nil)
    private let look = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let caption = NSTextField(wrappingLabelWithString: "")
    private var notice: String?
    private var state: (style: HomeAgentFoldStyle, expanded: Bool, team: Bool)

    /// Shows the playground (one window: a second call brings it front), switched to the given variant,
    /// folds, chat and look; with `peer` it then clicks that agent's pill.
    /// nil keeps what it shows (a new window: the shipped look, collapsed, the Chief's chat). `startsOwnAgents`
    /// gets each transcript it shows, for the queued pill menu's registered Start now row.
    public static func show(style: Int? = nil, expanded: Bool? = nil, team: Bool? = nil, peer: String? = nil, dark: Bool? = nil,
                            startsOwnAgents: ((HomeNativeTranscriptView) -> Void)? = nil) {
        let shown = NSApp.windows.first { $0.identifier == identifier }
        let playground = (shown?.contentView as? HomeAgentMessagePlaygroundView)?.owner
            ?? HomeAgentMessagePlayground(style: .current, expanded: false, team: false)
        let current = playground.state
        if let startsOwnAgents { playground.fixture.onShow = startsOwnAgents }
        if let dark { playground.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        playground.select(style.flatMap(HomeAgentFoldStyle.init(rawValue:)) ?? current.style,
                          expanded: expanded ?? current.expanded, team: team ?? current.team)
        playground.window.makeKeyAndOrderFront(nil)
        if let peer { playground.pillClicked(peer) }
    }

    private init(style: HomeAgentFoldStyle, expanded: Bool, team: Bool) {
        state = (style, expanded, team)
        fixture = HomeNativeFixture(playground: state)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        fixture.onPill = { [weak self] peer, _ in self?.pillClicked(peer) }
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
        picker.target = self
        picker.action = #selector(pickerChanged)
        for (control, action) in [(fold, #selector(foldChanged)), (chat, #selector(chatChanged)), (look, #selector(lookChanged))] {
            control.target = self
            control.action = action
        }
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 2
        let controls = NSStackView(views: [picker, fold, chat, look])
        controls.spacing = 12
        let bar = NSStackView(views: [controls, caption])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        for view in [bar, fixture.container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fixture.container.topAnchor.constraint(equalTo: bar.bottomAnchor),
            fixture.container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            fixture.container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fixture.container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
        fold.selectedSegment = state.expanded ? 1 : 0
        chat.selectedSegment = state.team ? 1 : 0
        look.selectedSegment = window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            || (window.appearance == nil && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ? 1 : 0
        caption.stringValue = notice ?? state.style.caption
    }

    // MARK: Pills

    /// A click on `peer`'s pill: in the app it opens the agent's workspace (cmux://workspace/…); the
    /// playground has no workspace, so it says where it would go.
    func pillClicked(_ peer: String) {
        notice = "A click opens \(peer)'s workspace, its chat focused. Home never splits."
        sync()
    }

    // MARK: Controls

    @objc private func pickerChanged() {
        guard let style = HomeAgentFoldStyle(rawValue: picker.indexOfSelectedItem) else { return }
        select(style, expanded: state.expanded, team: state.team)
    }

    @objc private func foldChanged() { select(state.style, expanded: fold.selectedSegment == 1, team: state.team) }

    @objc private func chatChanged() { select(state.style, expanded: state.expanded, team: chat.selectedSegment == 1) }

    @objc private func lookChanged() {
        window.appearance = NSAppearance(named: look.selectedSegment == 1 ? .darkAqua : .aqua)
    }

    public func windowWillClose(_ notification: Notification) {
        // The shipped look again for every Home view, then the playground lets go of its window and fixture.
        fixture.debugPlayground(style: .current, expanded: state.expanded, team: state.team)
        fixture.close()
        (window.contentView as? HomeAgentMessagePlaygroundView)?.owner = nil
    }
}
#endif
