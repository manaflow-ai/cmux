import AppKit
import SwiftUI

/// Hosts the Snippets keyboard-focus view inside SwiftUI and owns the local
/// key monitor that drives the list while the search field or the host has
/// focus: Up/Down, j/k and Ctrl+N/P move, Return activates, Escape returns
/// focus to the terminal, and "/" on the host focuses the search field.
struct SnippetsSidebarFocusBridge: NSViewRepresentable {
    static let searchFieldIdentifier = "SnippetsSidebarSearchField"

    let onMove: (Int) -> Void
    let onActivate: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> SnippetsKeyboardFocusView {
        let view = SnippetsKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ view: SnippetsKeyboardFocusView, context: Context) {
        context.coordinator.parent = self
        view.focusSearchField = { [weak view] in
            guard let view else { return false }
            return Self.focusSearchField(for: view)
        }
        view.ownsResponder = { [weak view] responder in
            guard let view else { return false }
            return Self.responderIsSearchField(responder, for: view)
        }
        view.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The search field in the host's window. The focus coordinator asks
    /// the host about every keystroke's responder, so the field is found by
    /// a view-tree walk once and then reused while it stays in that window.
    static func searchField(for host: SnippetsKeyboardFocusView) -> SidebarSearchField? {
        guard let window = host.window else { return nil }
        if let cached = host.cachedSearchField, cached.window === window {
            return cached
        }
        guard let root = window.contentView else { return nil }
        let found = firstSearchField(in: root)
        host.cachedSearchField = found
        return found
    }

    private static func firstSearchField(in view: NSView) -> SidebarSearchField? {
        if let field = view as? SidebarSearchField,
           field.accessibilityIdentifier() == searchFieldIdentifier {
            return field
        }
        for subview in view.subviews {
            if let found = firstSearchField(in: subview) { return found }
        }
        return nil
    }

    static func focusSearchField(for host: SnippetsKeyboardFocusView) -> Bool {
        guard let window = host.window, let field = searchField(for: host) else { return false }
        return window.makeFirstResponder(field)
    }

    static func responderIsSearchField(_ responder: NSResponder, for host: SnippetsKeyboardFocusView) -> Bool {
        guard responder is SidebarSearchField || responder is NSTextView,
              let field = searchField(for: host) else { return false }
        if responder === field { return true }
        if let textView = responder as? NSTextView, textView.delegate === field { return true }
        return false
    }

    /// What a key press does while the Snippets search field or host owns
    /// focus. Text entry keeps Return (the field submits it through its own
    /// delegate, honoring IME) and j/k (they type); an open IME composition
    /// keeps every key.
    enum KeyCommand: Equatable {
        case passThrough
        case escape
        case activate
        case focusSearch
        case move(Int)
    }

    static func keyCommand(for event: NSEvent, isTextEntry: Bool, isComposing: Bool) -> KeyCommand {
        if isComposing { return .passThrough }
        if event.keyCode == 53 { return .escape }
        if !isTextEntry, event.keyCode == 36 || event.keyCode == 76 { return .activate }
        if !isTextEntry, RightSidebarKeyboardNavigation.isPlainSlash(event) { return .focusSearch }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event),
           !(isTextEntry && (event.keyCode == 38 || event.keyCode == 40)) {
            return .move(delta)
        }
        return .passThrough
    }

    @MainActor
    final class Coordinator {
        var parent: SnippetsSidebarFocusBridge
        private var monitor: Any?

        init(parent: SnippetsSidebarFocusBridge) { self.parent = parent }

        func install(on host: SnippetsKeyboardFocusView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak host] event in
                // Local monitors run on the main thread; NSEvent is not
                // Sendable, so the result travels through a captured local.
                var result: NSEvent? = event
                MainActor.assumeIsolated {
                    result = self?.handle(event, host: host)
                }
                return result
            }
        }

        /// Returns nil when the key was consumed. Text entry stays with the
        /// field: Return reaches it as `insertNewline` (which submits through
        /// the field's own delegate, honoring IME composition) and j/k type.
        private func handle(_ event: NSEvent, host: SnippetsKeyboardFocusView?) -> NSEvent? {
            guard let host, let window = host.window, window.isKeyWindow,
                  let responder = window.firstResponder, host.ownsKeyboardFocus(responder) else {
                return event
            }
            let command = SnippetsSidebarFocusBridge.keyCommand(
                for: event,
                isTextEntry: responder !== host,
                isComposing: (responder as? NSTextView)?.hasMarkedText() == true
            )
            switch command {
            case .passThrough:
                return event
            case .escape:
                parent.onEscape()
            case .activate:
                parent.onActivate()
            case .focusSearch:
                _ = SnippetsSidebarFocusBridge.focusSearchField(for: host)
            case .move(let delta):
                parent.onMove(delta)
            }
            return nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
