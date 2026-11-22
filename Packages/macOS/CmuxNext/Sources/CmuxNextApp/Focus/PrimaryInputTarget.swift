import AppKit

/// A surface's primary input (R65, spec app-screens.md section 3): Home's
/// message box, the agent pane's composer, an app screen's
/// `presentation.primaryInput`. When the surface has the keyboard and none
/// of its text fields has focus, the key dispatcher sends a printable key
/// here, so typing starts in the primary input and the first key is not
/// lost. Command and Control chords resolve in the dispatcher first.
///
/// A surface opts in by conforming its content view (`TabContent.view`).
@MainActor
protocol PrimaryInputTarget: AnyObject {
    /// None of the surface's text fields has the keyboard now.
    var acceptsRedirectedTyping: Bool { get }
    /// Focuses the primary input and types `event` into it.
    func beginTyping(with event: NSEvent)
}

extension TabContent {
    /// The content's primary input, when its view (an internal page's
    /// provider view) declares one.
    @MainActor var primaryInput: (any PrimaryInputTarget)? {
        if case .page(let page) = self { return page.content as? any PrimaryInputTarget }
        return view as? any PrimaryInputTarget
    }
}

extension KeyRouter {
    /// A key that types text: no Command or Control, and a character that
    /// is neither a control character nor a function key (arrows, Return,
    /// Tab, Escape, Delete stay the surface's).
    nonisolated static func isPrintable(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isChord(event.modifierFlags),
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    /// Surfaces that may declare a primary input.
    nonisolated static func mayHavePrimaryInput(_ resolved: FocusState.Resolved) -> Bool {
        switch resolved {
        case .conversation, .agentPage, .page: true
        default: false
        }
    }
}
