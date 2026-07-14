import Testing

@testable import CmuxVoice

@Suite
struct DictationInsertionRouteResolverTests {
    private let resolver = DictationInsertionRouteResolver()

    @Test func nativeTextResponderWinsOverEverything() {
        let route = resolver.route(
            firstResponderIsTextInput: true,
            firstResponderIsWebView: true,
            hasFocusedTerminalSurface: true
        )
        #expect(route == .nativeTextResponder)
    }

    @Test func webViewWinsOverTerminal() {
        let route = resolver.route(
            firstResponderIsTextInput: false,
            firstResponderIsWebView: true,
            hasFocusedTerminalSurface: true
        )
        #expect(route == .webViewEditable)
    }

    @Test func terminalIsTheFallbackTarget() {
        let route = resolver.route(
            firstResponderIsTextInput: false,
            firstResponderIsWebView: false,
            hasFocusedTerminalSurface: true
        )
        #expect(route == .terminalSurface)
    }

    @Test func noFocusMeansNoRoute() {
        let route = resolver.route(
            firstResponderIsTextInput: false,
            firstResponderIsWebView: false,
            hasFocusedTerminalSurface: false
        )
        #expect(route == nil)
    }
}
