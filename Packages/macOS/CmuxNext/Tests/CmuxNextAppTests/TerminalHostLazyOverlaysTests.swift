import AppKit
@testable import CmuxNextTerminal
import Testing

/// A new terminal builds no Restart, Retry or "Sized for" button: each is a rounded NSButton whose
/// bezel is sized and laid out through SwiftUI, measured in every split's first frame
/// (app-eff/split-close-cost). Each is built the first time it shows, and then shows as before.
@MainActor @Suite struct TerminalHostLazyOverlaysTests {
    static func buttons(in host: NSView) -> [NSButton] {
        host.subviews.flatMap { view in (view as? NSButton).map { [$0] } ?? buttons(in: view) }
    }

    @Test func aNewTerminalHasNoButtons() {
        let host = TerminalHostView()
        host.showStatus(.connected)
        host.onRestart = {}
        host.showSizedFor(nil)
        #expect(Self.buttons(in: host).isEmpty)
        #expect(host.sizedForText == nil)
    }

    @Test func restartShowsOnceTheShellEndedWithAnAction() {
        let host = TerminalHostView()
        host.showStatus(.exited)
        #expect(Self.buttons(in: host).isEmpty, "no action: no button")
        var restarted = false
        host.onRestart = { restarted = true }
        let restart = Self.buttons(in: host).compactMap { $0 as? TerminalRestartButton }
        #expect(restart.count == 1)
        #expect(restart.first?.isHidden == false)
        restart.first?.onRestart?()
        #expect(restarted)
        host.showStatus(.connected)
        #expect(restart.first?.isHidden == true)
        host.onRestart = nil
        host.showStatus(.exited)
        #expect(restart.first?.isHidden == true, "the action went away")
    }

    @Test func retryShowsOnlyForAFailedAttach() {
        let host = TerminalHostView()
        host.showStatus(.disconnected(.connectionLost, reconnecting: true))
        host.showStatus(.disconnected(.turnedOffByOrganization, reconnecting: false))
        #expect(Self.buttons(in: host).isEmpty)
        host.showStatus(.disconnected(.attachFailed, reconnecting: false))
        let retry = Self.buttons(in: host).compactMap { $0 as? TerminalRetryButton }
        #expect(retry.count == 1)
        #expect(retry.first?.isHidden == false)
        host.showStatus(.connected)
        #expect(retry.first?.isHidden == true)
    }

    @Test func sizedForBuildsTheChipWhenItShows() {
        let host = TerminalHostView()
        let notice = TerminalSizedFor(deviceName: "Maya's iPhone", deviceKind: "iphone", sameDevice: false,
                                      grid: TerminalGridSize(columns: 54, rows: 44))
        host.showSizedFor(notice)
        #expect(host.sizedForText == "Sized for Maya's iPhone · 54×44")
        #expect(Self.buttons(in: host).count == 1)
        host.showSizedFor(nil)
        #expect(host.sizedForText == nil)
        host.showSizedFor(notice)
        #expect(Self.buttons(in: host).count == 1, "built once")
    }
}
