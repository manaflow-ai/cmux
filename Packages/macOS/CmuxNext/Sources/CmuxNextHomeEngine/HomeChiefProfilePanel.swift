public import AppKit
import CmuxNextDesign

/// The Chief's profile (``HomeChiefProfileView``) as a panel beside a Home chat (Lawrence's
/// reference, 2026-11-04, after Grok's bot panel; it replaced the settings popover under the name
/// pill). Side by side with the chat when the pane has room for both, over the chat when it does not,
/// with a hairline between them. The Home view owns one and lays the chat out through it.
@MainActor
public final class HomeChiefProfilePanel {
    public let view: HomeChiefProfileView
    let divider = NSView()
    /// The computer the control bar changes now (``follow(agent:machine:make:)``).
    private var controlKey: [String?]?

    public init(settings: HomeChiefSettingsView) {
        view = HomeChiefProfileView(settings: settings)
        view.isHidden = true
        view.wantsLayer = true
        divider.wantsLayer = true
        divider.isHidden = true
    }

    /// Puts the panel over `host`'s other subviews (add it after the chat).
    public func install(in host: NSView) {
        host.addSubview(divider)
        host.addSubview(view)
    }

    /// The panel is open.
    public var isShown: Bool { !view.isHidden }

    /// Opens the panel at `tab` (nil: the tab it showed last).
    public func open(_ tab: HomeChiefProfileTab?) {
        if let tab { view.select(tab) }
        guard view.isHidden else { return }
        view.isHidden = false
        view.superview?.needsDisplay = true
        view.superview?.needsLayout = true
    }

    /// Closes the panel (it keeps a name being edited); the keyboard goes to `chat` when it was in the panel.
    public func close(keyboardTo chat: NSView) {
        guard isShown else { return }
        let hadKeyboard = holdsKeyboard(view.window?.firstResponder)
        view.isHidden = true
        divider.isHidden = true
        view.superview?.needsLayout = true
        if hadKeyboard { chat.window?.makeFirstResponder(chat) }
    }

    /// Whether `responder` is in the open panel: its keys stay there (the Chief's screen, while the
    /// person drives the computer, takes every key), and a pane focus leaves it there.
    public func holdsKeyboard(_ responder: NSResponder?) -> Bool {
        guard isShown, let responder = responder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    /// Lays out `chat` and the panel in `bounds`.
    public func layout(chat: NSView, in bounds: NSRect) {
        guard isShown else {
            chat.frame = bounds
            return
        }
        let frames = Self.frames(in: bounds)
        view.frame = frames.panel
        chat.frame = frames.chat
        divider.isHidden = frames.divider == nil
        if let line = frames.divider { divider.frame = line }
    }

    /// The panel's, the chat's and the hairline's frames in `bounds`: side by side when both fit
    /// (the chat at least as wide as the panel), else the panel over the whole of it and no hairline.
    static func frames(in bounds: NSRect) -> (panel: NSRect, chat: NSRect, divider: NSRect?) {
        let width = HomeChiefProfileView.panelWidth
        guard bounds.width >= 2 * width else { return (bounds, bounds, nil) }
        let panel = NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        let line = NSRect(x: panel.minX - 1, y: bounds.minY, width: 1, height: bounds.height)
        return (panel, NSRect(x: bounds.minX, y: bounds.minY, width: line.minX - bounds.minX, height: bounds.height), line)
    }

    /// The panel's fill and its hairline, in the theme of the view drawing them (call inside its theme scope).
    public func applyTheme() {
        view.layer?.backgroundColor = Palette.paneFill.cgColor
        divider.layer?.backgroundColor = Palette.paneBorder.cgColor
    }

    /// The computer the Computer tab's control bar changes: a Cloud Chief's own sandbox (`agent`), else
    /// the Cloud machine a Chief of this Mac uses (`machine`), else none. `make` builds the source; a new
    /// one only when the computer changed, and again while the app had none to give.
    public func follow(agent: String?, machine: String?, make: (String?, String?) -> HomeChiefComputerControlSource?) {
        let key = [agent, machine]
        guard key != controlKey, !view.pinsControl else { return }
        let source = agent == nil && machine == nil ? nil : make(agent, machine)
        if source != nil || view.control != nil { view.control = source }
        controlKey = source == nil ? nil : key
    }
}
