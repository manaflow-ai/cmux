public import AppKit

/// A window's traffic-light buttons, found once. AppKit asks the window for them each time it
/// rebuilds the titlebar drag regions (`_resetDragMargins`, after a view frame or first-responder
/// change), and its own lookup searches the whole view tree: about 7 ms per tab switch in a
/// 16-pane window (cx-8w027.25). A window subclass answers `standardWindowButton(_:)` from here.
/// A button AppKit replaced (a style or full-screen change) has left the window, so the cache
/// misses and looks again. A type the window does not have is an answer too, kept while the window shape holds.
@MainActor
public struct StandardWindowButtons {
    private var buttons: [NSWindow.ButtonType: NSButton] = [:]
    /// Types AppKit answered with no button, and the window shape that answer holds for.
    private var absent: [NSWindow.ButtonType: Shape] = [:]
    /// The types whose absent answer is kept: the ones a titled window without a document or toolbar button never has.
    /// The traffic lights are not here: while a window leaves full screen they are briefly in the full-screen titlebar
    /// (`WindowTitlebar.trafficLightsFrame`), and a nil kept from that moment would hide them for good.
    private static let keepsAbsent: Set<NSWindow.ButtonType> = [.documentIconButton, .documentVersionsButton, .toolbarButton]

    /// A part of what decides whether a window has one of those buttons: its style, its toolbar and its frame view.
    /// A document window (`representedURL`) keeps no absent answer at all: AppKit can add its document icon or versions
    /// button with no change here (lazily, or when `isDocumentEdited` changes).
    struct Shape: Equatable {
        let style: NSWindow.StyleMask.RawValue
        let toolbar: Bool
        let frameView: ObjectIdentifier?

        /// The shape of `window` now, or nil for a document window (no absent answer holds for it).
        @MainActor init?(_ window: NSWindow) {
            guard window.representedURL == nil else { return nil }
            style = window.styleMask.rawValue
            toolbar = window.toolbar != nil
            frameView = window.contentView?.superview.map(ObjectIdentifier.init)
        }
    }

    /// AppKit's answer for one type, with everything the cache keeps from the window, read before any access to the
    /// cache: an AppKit getter (style, `representedURL`, toolbar, frame view) can ask the window for a button again, and
    /// that read during `store`'s change of the cache would stop the app (Swift exclusivity, also in Release).
    public struct Found {
        let type: NSWindow.ButtonType
        let button: NSButton?
        let absentShape: Shape?

        @MainActor public init(_ button: NSButton?, for type: NSWindow.ButtonType, in window: NSWindow) {
            self.type = type
            self.button = button?.window === window ? button : nil
            absentShape = button == nil && StandardWindowButtons.keepsAbsent.contains(type) ? Shape(window) : nil
        }
    }

    public init() {}

    /// What the cache knows about `type` in `window`: `.unknown` (ask AppKit, then `store`), or AppKit's answer.
    public enum Answer {
        case unknown
        case known(NSButton?)
    }

    /// The cached answer for `type` in `window`. Ask AppKit only on `.unknown`.
    public func answer(_ type: NSWindow.ButtonType, in window: NSWindow) -> Answer {
        if let button = cached(type, in: window) { return .known(button) }
        if let shape = absent[type], shape == Shape(window) { return .known(nil) }
        return .unknown
    }

    /// The cached `type` button of `window`, while it is still in `window`.
    public func cached(_ type: NSWindow.ButtonType, in window: NSWindow) -> NSButton? {
        guard let button = buttons[type], button.window === window, button.superview != nil else { return nil }
        return button
    }

    /// Keeps AppKit's answer. Make `found` before this call, outside any access to this value: it reads AppKit getters,
    /// and AppKit may ask the window again while they run (``Found``).
    public mutating func store(_ found: Found) {
        buttons[found.type] = found.button
        absent[found.type] = found.absentShape
    }
}
