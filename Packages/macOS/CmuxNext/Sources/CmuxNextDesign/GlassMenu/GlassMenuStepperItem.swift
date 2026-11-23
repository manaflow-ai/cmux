public import AppKit

/// A ``GlassMenu`` row with a value and three buttons in it: −, the value, +, and a reset. Pressing
/// a button runs its item and the menu stays open, so the person sees the new value and can press
/// again (the browser More menu's zoom row: Zoom Out, the percent, Zoom In, Actual Size).
///
/// The three buttons are plain menu items (an action registry's rows), so they keep their own
/// validation, titles and shortcuts: a button is enabled while its item validates, its title is the
/// button's VoiceOver label, and its key equivalent pressed while the menu is open runs it without
/// closing the menu. Only a ``GlassMenu`` draws the buttons: put the row in menus it shows.
///
/// With the keys on the row, Left runs ``decrement``, Right runs ``increment`` and Return runs
/// ``reset``.
///
/// ```swift
/// let zoom = GlassMenuStepperItem(title: "Zoom", decrement: zoomOut, increment: zoomIn, reset: actualSize) {
///     "\(BrowserZoom.percent(tab.state.zoom))%"
/// }
/// menu.addItem(zoom)
/// ```
// Nonisolated as NSMenuItem is (its inherited initializers are); every member that touches the menu
// is main-actor.
nonisolated public final class GlassMenuStepperItem: NSMenuItem {
    /// The − button's item.
    public let decrement: NSMenuItem
    /// The + button's item.
    public let increment: NSMenuItem
    /// The reset button's item (drawn as a circular arrow after the + button).
    public let reset: NSMenuItem
    /// The text between − and +, read when the menu opens and after each press.
    public let value: @MainActor () -> String
    /// Holds the three items so they validate and run as rows of a menu do.
    private let parts: NSMenu

    /// A stepper row titled `title`.
    ///
    /// - Parameters:
    ///   - title: the row's label, before the buttons ("Zoom").
    ///   - decrement: the − button's item; it leaves the menu it was in, and the three validate as that
    ///     menu validated its items (autoenabling or not).
    ///   - increment: the + button's item; it leaves the menu it was in.
    ///   - reset: the reset button's item; it leaves the menu it was in.
    ///   - value: the text between − and + ("110%").
    @MainActor
    public init(title: String, decrement: NSMenuItem, increment: NSMenuItem, reset: NSMenuItem,
                value: @escaping @MainActor () -> String) {
        parts = NSMenu()
        // The items validate as in the menu they came from: by their targets when it autoenables,
        // else by their own isEnabled.
        parts.autoenablesItems = decrement.menu?.autoenablesItems ?? true
        self.decrement = decrement
        self.increment = increment
        self.reset = reset
        self.value = value
        super.init(title: title, action: #selector(GlassMenuStepperItem.stay(_:)), keyEquivalent: "")
        // Its own target, so an autoenabling menu keeps the row enabled (the highlight stops on it);
        // the row itself runs nothing.
        target = self
        for item in [decrement, increment, reset] {
            item.menu?.removeItem(item)
            parts.addItem(item)
        }
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The row's own action: nothing (its buttons run their items).
    @objc func stay(_ sender: Any?) {}

    /// Validates the three items (their targets' `validateMenuItem`), so ``isEnabled(_:)`` is current.
    @MainActor func validate() { parts.update() }

    /// Whether `part` (one of the three items) can run now.
    @MainActor func isEnabled(_ part: NSMenuItem) -> Bool { part.isEnabled && !part.isHidden }

    /// Runs `part` (one of the three items) at once, as a chosen menu item runs, if it is enabled.
    /// Returns whether it ran.
    @discardableResult
    @MainActor func run(_ part: NSMenuItem) -> Bool {
        validate()
        let index = parts.index(of: part)
        guard index >= 0, isEnabled(part) else { return false }
        parts.performActionForItem(at: index)
        return true
    }

    /// The item of the three whose key equivalent `event` presses, as ``GlassMenuRow/item(matching:in:)``
    /// finds a row's.
    @MainActor func part(matching event: NSEvent) -> NSMenuItem? {
        validate()
        return GlassMenuRow.item(matching: event, in: parts)
    }
}
