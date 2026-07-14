import Foundation

/// Decides which insertion route a dictation session should pin, given a
/// snapshot of the app's focus state.
///
/// The priority is deliberate: a focused native text input always wins (it
/// is literally what keystrokes would reach), then editable web content in
/// the key `WKWebView`, then the workspace's focused terminal surface.
///
/// ```swift
/// let resolver = DictationInsertionRouteResolver()
/// resolver.route(
///     firstResponderIsTextInput: false,
///     firstResponderIsWebView: false,
///     hasFocusedTerminalSurface: true
/// ) // → .terminalSurface
/// ```
public struct DictationInsertionRouteResolver: Sendable {
    /// Creates a resolver.
    public init() {}

    /// Picks the insertion route for the given focus snapshot.
    ///
    /// - Parameters:
    ///   - firstResponderIsTextInput: The key window's first responder is an
    ///     `NSTextView`/`NSTextField` (or a field editor).
    ///   - firstResponderIsWebView: The first responder is (or descends
    ///     from) a `WKWebView`.
    ///   - hasFocusedTerminalSurface: The active workspace has a focused
    ///     terminal panel.
    /// - Returns: The route to pin, or `nil` when nothing insertable has
    ///   focus.
    public func route(
        firstResponderIsTextInput: Bool,
        firstResponderIsWebView: Bool,
        hasFocusedTerminalSurface: Bool
    ) -> DictationInsertionRoute? {
        if firstResponderIsTextInput { return .nativeTextResponder }
        if firstResponderIsWebView { return .webViewEditable }
        if hasFocusedTerminalSurface { return .terminalSurface }
        return nil
    }
}
