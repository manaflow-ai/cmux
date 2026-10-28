import AppKit
@testable import CmuxNextTerminal
import Testing

/// VoiceOver hears the terminal's status banner (pro audit 16). The banner ("Process exited",
/// "Reconnecting to the shell…") is the only cue that the shell stopped, and it never spoke: a
/// VoiceOver user typing into the terminal kept typing into a dead shell. A new message is
/// announced once, only for the terminal that has the keyboard; "Restoring…" (usually gone in
/// half a second) and the same message again stay silent.
@MainActor struct TerminalStatusBannerAnnouncementTests {
    /// A window whose first responder sits in the banner's terminal (`focused`) or outside it.
    private func host(focused: Bool) -> (TerminalStatusBanner, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let root = NSView(frame: window.contentLayoutRect)
        let terminal = NSView(frame: root.bounds)
        let surface = NSTextView(frame: terminal.bounds)
        let elsewhere = NSTextView(frame: root.bounds)
        let banner = TerminalStatusBanner()
        terminal.addSubview(surface)
        terminal.addSubview(banner)
        root.addSubview(elsewhere)
        root.addSubview(terminal)
        window.contentView = root
        window.makeFirstResponder(focused ? surface : elsewhere)
        return (banner, window)
    }

    @Test func aNewStatusIsAnnouncedOnceForTheFocusedTerminal() {
        let (banner, window) = host(focused: true)
        var heard: [String] = []
        banner.announce = { heard.append($0) }

        banner.show(.restoring)
        #expect(heard.isEmpty, "Restoring… is announced")
        banner.show(.exited)
        #expect(heard == [TerminalStatusBanner.text(for: .exited)].compactMap(\.self), "the ended shell was not announced")
        banner.show(.exited)
        #expect(heard.count == 1, "the same message was announced again")
        banner.show(.connected)
        banner.show(.exited)
        #expect(heard.count == 2, "a second exit after a reconnect stayed silent")
        withExtendedLifetime(window) {}
    }

    @Test func aTerminalWithoutTheKeyboardStaysSilent() {
        let (banner, window) = host(focused: false)
        var heard: [String] = []
        banner.announce = { heard.append($0) }
        banner.show(.exited)
        #expect(heard.isEmpty)
        withExtendedLifetime(window) {}
    }
}
