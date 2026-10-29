import AppKit
import CmuxNextDesign

/// The chat's Session Info, drawn by the App (``AgentPaneSessionInfo``): the shared overlay glass
/// floating over the agent pane at its right, from under the header to the pane's foot (Leo,
/// 2026-10-26: "you still haven't done the full-length thing"). It floats: it never takes a column
/// and never moves the chat's layout; the page shifts the chat left only when both fit
/// (design/session-info.md rule 2, `inspectorChatShift`). No close button and no band at its top:
/// its header toggle and Esc close it. Its left edge drags its width.
final class AgentPaneSessionInfoPanel: NSView {
    let store: AgentPaneSessionInfoStore
    private let glass: OverlaySurfaceView
    private let edge = AgentPaneSessionInfoEdge()

    init(store: AgentPaneSessionInfoStore) {
        self.store = store
        let content = AgentPaneSessionInfoContent(store: store)
        glass = Glass.makeOverlayPanel(content: content)
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        edge.autoresizingMask = [.height, .maxXMargin]
        addSubview(edge)
        edge.onDrag = { [weak self] delta, ended in self?.store.drag(by: delta, ended: ended) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        edge.frame = CGRect(x: 0, y: 0, width: AgentPaneSessionInfoEdge.width, height: bounds.height)
    }

    /// Esc from inside the panel closes it, as the page's did.
    override func cancelOperation(_ sender: Any?) { store.act("close") }
}

/// What the panel draws and how its clicks reach the page.
@MainActor final class AgentPaneSessionInfoStore {
    var info: AgentPaneSessionInfoModel? { didSet { if info != oldValue { redraw() } } }
    var colors = AgentPaneSessionInfoColors() { didSet { if colors != oldValue { redraw() } } }
    /// Points per CSS pixel: the page's zoom.
    var zoom: CGFloat = 1
    /// The width a drag of the left edge gives the panel before the page hears it, CSS pixels.
    var dragWidth: Double?
    /// Sends a row's, a button's or the panel's own action id to the page.
    var send: (String) -> Void = { _ in }
    /// The panel's frame needs laying out again (a drag step).
    var relayout: () -> Void = {}
    /// The content draws the model or the colors again (AgentPaneSessionInfoContent).
    var redraw: () -> Void = {}

    /// The panel's width in CSS pixels: the drag's while one runs, else the page's.
    var width: Double { dragWidth ?? info?.width ?? 0 }

    func act(_ id: String) { send(id) }

    /// The left edge moved `delta` points (positive: right, narrower); at the end the page keeps the
    /// width (its `INSPECTOR_WIDTH` bounds it).
    func drag(by delta: CGFloat, ended: Bool) {
        guard let info else { return }
        let next = min(560, max(260, (dragWidth ?? info.width) - Double(delta / max(0.25, zoom))))
        dragWidth = next
        relayout()
        guard ended else { return }
        send("width:\(Int(next.rounded()))")
    }

    /// The page answered with its width: the drag is over.
    func update(_ next: AgentPaneSessionInfoModel?) {
        if let next, let dragWidth, abs(next.width - dragWidth) < 1 { self.dragWidth = nil }
        if next == nil { dragWidth = nil }
        info = next
    }
}

/// The pane's theme colors, resolved by the view from its tokens.
struct AgentPaneSessionInfoColors: Equatable {
    var primary = ThemeTokens.unresolved.textPrimary.nsColor
    var secondary = ThemeTokens.unresolved.textSecondary.nsColor
    var tertiary = ThemeTokens.unresolved.textTertiary.nsColor
    var hover = ThemeTokens.unresolved.hoverFill.nsColor
    var separator = ThemeTokens.unresolved.separator.nsColor
    var danger = ThemeTokens.unresolved.danger.nsColor
    var success = ThemeTokens.unresolved.success.nsColor
    var attention = ThemeTokens.unresolved.attention.nsColor
    var accent = ThemeTokens.unresolved.litGlyph.nsColor

    init() {}

    init(_ tokens: ThemeTokens) {
        primary = tokens.textPrimary.nsColor
        secondary = tokens.textSecondary.nsColor
        tertiary = tokens.textTertiary.nsColor
        hover = tokens.hoverFill.nsColor
        separator = Borders.color(tokens.separator.nsColor)
        danger = tokens.danger.nsColor
        success = tokens.success.nsColor
        attention = tokens.attention.nsColor
        accent = tokens.litGlyph.nsColor
    }

    func tone(_ tone: AgentPaneSessionInfoModel.Tone?) -> NSColor {
        switch tone {
        case .failed: danger
        case .waiting: attention
        case .accent: accent
        case .muted, .done: tertiary
        case .running, nil: secondary
        }
    }
}

/// The panel's left edge: a resize cursor and a horizontal drag.
final class AgentPaneSessionInfoEdge: NSView {
    static let width: CGFloat = 6
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) { step(event, ended: false) }
    override func mouseUp(with event: NSEvent) { step(event, ended: true) }

    private func step(_ event: NSEvent, ended: Bool) {
        guard let start = last else { return }
        let x = event.locationInWindow.x
        last = ended ? nil : x
        onDrag?(x - start, ended)
    }
}

