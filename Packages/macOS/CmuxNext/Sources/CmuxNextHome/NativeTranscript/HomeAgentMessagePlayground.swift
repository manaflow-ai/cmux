#if DEBUG
public import AppKit
public import MessagesLabHome

/// DEBUG ONLY: Debug > Agent Messages Playground (user 2026-11-02, msg 19613: "i want playground in swift,
/// not html"). One window with the real Home transcript over the mock owner (``HomeNativeFixture``) and a
/// bar that switches, live, the agent-message header variant (``HomeAgentFoldStyle``), collapsed or
/// expanded, in the Chief's own chat or a team chat (where the Chief's avatar and name draw).
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
    private let caption = NSTextField(wrappingLabelWithString: "")
    private var state: (style: HomeAgentFoldStyle, expanded: Bool, team: Bool)

    /// Shows the playground (one window: a second call brings it front), switched to the given variant,
    /// folds and chat; nil keeps what it shows (a new window: the shipped look, collapsed, the Chief's chat).
    public static func show(style: Int? = nil, expanded: Bool? = nil, team: Bool? = nil) {
        let shown = NSApp.windows.first { $0.identifier == identifier }
        let playground = (shown?.contentView as? HomeAgentMessagePlaygroundView)?.owner
            ?? HomeAgentMessagePlayground(style: .current, expanded: false, team: false)
        let current = playground.state
        playground.select(style.flatMap(HomeAgentFoldStyle.init(rawValue:)) ?? current.style,
                          expanded: expanded ?? current.expanded, team: team ?? current.team)
        playground.window.makeKeyAndOrderFront(nil)
    }

    private init(style: HomeAgentFoldStyle, expanded: Bool, team: Bool) {
        state = (style, expanded, team)
        fixture = HomeNativeFixture(playground: state)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
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
        fold.target = self
        fold.action = #selector(foldChanged)
        chat.target = self
        chat.action = #selector(chatChanged)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 2
        let controls = NSStackView(views: [picker, fold, chat])
        controls.spacing = 12
        let bar = NSStackView(views: [controls, caption])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let transcript = fixture.container
        for view in [bar, transcript] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: bar.bottomAnchor),
            transcript.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
        caption.stringValue = state.style.caption
    }

    @objc private func pickerChanged() {
        guard let style = HomeAgentFoldStyle(rawValue: picker.indexOfSelectedItem) else { return }
        select(style, expanded: state.expanded, team: state.team)
    }

    @objc private func foldChanged() { select(state.style, expanded: fold.selectedSegment == 1, team: state.team) }

    @objc private func chatChanged() { select(state.style, expanded: state.expanded, team: chat.selectedSegment == 1) }

    public func windowWillClose(_ notification: Notification) {
        // The shipped look again for every Home view, then the playground lets go of its window and fixture.
        fixture.debugPlayground(style: .current, expanded: state.expanded, team: state.team)
        fixture.close()
        (window.contentView as? HomeAgentMessagePlaygroundView)?.owner = nil
    }
}
#endif
