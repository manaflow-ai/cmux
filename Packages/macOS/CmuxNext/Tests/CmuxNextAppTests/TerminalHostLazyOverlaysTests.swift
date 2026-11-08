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

/// The Fix chip (design/terminal-fix-chip-gallery.html A): a failed command offers Fix while the App gave an action;
/// success, Ctrl-C, Return, the close button and Fix itself hide it, and it is built once, the first time it shows.
@MainActor @Suite struct TerminalFixChipTests {
    static func failed(_ code: Int?) -> TerminalCommandResult { TerminalCommandResult(exitCode: code, duration: .seconds(1)) }

    @Test func aFailureOffersFixOnlyWithAnAction() {
        let host = TerminalHostView()
        host.commandFinished(Self.failed(101))
        #expect(host.fixChipText == nil, "no action, no chip")
        #expect(TerminalHostLazyOverlaysTests.buttons(in: host).isEmpty)
        var fixed = 0
        host.onFixCommand = { fixed += 1 }
        host.commandFinished(Self.failed(101))
        #expect(host.fixChipText == "Exit 101")
        host.commandFinished(Self.failed(0))
        #expect(host.fixChipText == nil, "a success hides it")
        host.commandFinished(Self.failed(130))
        #expect(host.fixChipText == nil, "Ctrl-C is the person's choice")
        host.commandFinished(Self.failed(nil))
        #expect(host.fixChipText == nil, "no status is not a failure")
        host.commandFinished(Self.failed(2))
        let fix = TerminalHostLazyOverlaysTests.buttons(in: host).first { $0.title == "Fix" }
        fix?.performClick(nil)
        #expect(fixed == 1)
        #expect(host.fixChipText == nil, "Fix hides it")
        #expect(TerminalHostLazyOverlaysTests.buttons(in: host).count == 2, "built once: Fix and close")
    }

    @Test func returnAndTheCloseButtonHideIt() {
        let host = TerminalHostView()
        host.onFixCommand = {}
        host.commandFinished(Self.failed(1))
        #expect(host.offersFix)
        host.commandSubmitted()
        #expect(!host.offersFix)
        host.commandFinished(Self.failed(1))
        let close = TerminalHostLazyOverlaysTests.buttons(in: host).first { $0.title.isEmpty }
        close?.performClick(nil)
        #expect(!host.offersFix)
        host.commandFinished(Self.failed(1))
        host.onFixCommand = nil
        #expect(!host.offersFix, "taking the action away hides it")
    }
}
