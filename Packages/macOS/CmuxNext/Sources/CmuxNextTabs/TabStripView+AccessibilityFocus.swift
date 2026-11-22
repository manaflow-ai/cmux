import AppKit

// VoiceOver focus inside the strip reveals the hover-only plus
// (`TabStripButtonReveal.accessibilityFocused`): the strip element itself,
// a tab's element or the plus. Each reports focus on and off; the plus
// shows while any of them holds it, so a move from a tab to the plus never
// hides it in between.
extension TabStripView {
    /// Element `element` of this strip gained (true) or lost (false) VoiceOver focus.
    func noteAccessibilityFocus(_ element: ObjectIdentifier, _ focused: Bool) {
        if focused {
            accessibilityFocusedElements.insert(element)
        } else {
            accessibilityFocusedElements.remove(element)
        }
        let any = !accessibilityFocusedElements.isEmpty
        if buttonReveal.accessibilityFocused != any { buttonReveal.accessibilityFocused = any }
    }
}
