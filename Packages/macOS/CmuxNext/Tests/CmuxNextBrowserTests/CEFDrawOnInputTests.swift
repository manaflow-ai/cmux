@testable import CmuxNextBrowser
import Foundation
import Testing

/// Agent chat pages ask the fork to draw a key's frame at once (fork API 35, `CEFDrawOnInput`): only agent chats, only
/// with the Debug Settings toggle on, only with an engine that has the call, and every open chat follows the toggle.
@MainActor @Suite struct CEFDrawOnInputTests {
    /// The fork calls made, in order.
    final class Fork {
        var calls: [(browser: Int32, enabled: Bool)] = []
        var takes = true
        func call(_ browser: Int32, _ enabled: Bool) -> Bool {
            calls.append((browser, enabled))
            return takes
        }
    }

    final class Toggle {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    let chat = URL(string: "cmux-page://cmux.agent/?session=s1")
    let settings = URL(string: "cmux-page://cmux.settings/")
    let web = URL(string: "https://example.com/")

    func make(_ fork: Fork, _ toggle: Toggle) -> CEFDrawOnInput {
        CEFDrawOnInput(call: { fork.call($0, $1) }, isOn: { toggle.on })
    }

    @Test func agentChatOptsInWhenTheToggleIsOn() {
        let fork = Fork()
        let draw = make(fork, Toggle(true))
        draw.addressChanged(browser: 7, url: chat)
        #expect(fork.calls.map(\.browser) == [7])
        #expect(fork.calls.map(\.enabled) == [true])
        #expect(draw.drawing == [7])
        // The same chat again asks nothing more.
        draw.addressChanged(browser: 7, url: chat)
        #expect(fork.calls.count == 1)
    }

    @Test func otherPagesAndAnOffToggleAskNothing() {
        let fork = Fork()
        let on = make(fork, Toggle(true))
        on.addressChanged(browser: 1, url: settings)
        on.addressChanged(browser: 2, url: web)
        on.addressChanged(browser: 3, url: nil)
        let off = make(fork, Toggle(false))
        off.addressChanged(browser: 4, url: chat)
        #expect(fork.calls.isEmpty)
        #expect(on.drawing.isEmpty && off.drawing.isEmpty)
    }

    @Test func leavingTheChatOptsOut() {
        let fork = Fork()
        let draw = make(fork, Toggle(true))
        draw.addressChanged(browser: 7, url: chat)
        draw.addressChanged(browser: 7, url: web)
        #expect(fork.calls.map(\.enabled) == [true, false])
        #expect(draw.drawing.isEmpty)
    }

    @Test func openChatsFollowTheToggle() {
        let fork = Fork()
        let toggle = Toggle(false)
        let draw = make(fork, toggle)
        draw.addressChanged(browser: 7, url: chat)
        draw.addressChanged(browser: 8, url: web)
        #expect(fork.calls.isEmpty)
        toggle.on = true
        draw.settingChanged()
        #expect(fork.calls.map(\.browser) == [7])
        #expect(draw.drawing == [7])
        toggle.on = false
        draw.settingChanged()
        #expect(fork.calls.map(\.enabled) == [true, false])
        #expect(draw.drawing.isEmpty)
    }

    @Test func aClosedChatIsForgotten() {
        let fork = Fork()
        let toggle = Toggle(true)
        let draw = make(fork, toggle)
        draw.addressChanged(browser: 7, url: chat)
        draw.closed(browser: 7)
        toggle.on = false
        draw.settingChanged()
        #expect(fork.calls.count == 1)
        #expect(draw.drawing.isEmpty)
    }

    @Test func aRefusedCallIsAskedAgainNextTime() {
        let fork = Fork()
        fork.takes = false
        let draw = make(fork, Toggle(true))
        draw.addressChanged(browser: 7, url: chat)
        #expect(draw.drawing.isEmpty)
        fork.takes = true
        draw.addressChanged(browser: 7, url: chat)
        #expect(draw.drawing == [7])
        #expect(fork.calls.count == 2)
    }

    /// An engine below fork API 35 (today's cmux.52 is 34) gets no call at all, with the toggle on.
    @Test func anOlderEngineGetsNoCall() {
        #expect(CEFDrawOnInput.forkAPI == 35)
        let draw = CEFDrawOnInput(shim: nil, apiVersion: 34)
        draw.addressChanged(browser: 7, url: chat)
        draw.settingChanged()
        #expect(draw.drawing.isEmpty)
    }

    @Test func theToggleIsOffByDefaultAndListedInDebugSettings() {
        #expect(CEFDrawOnInput.setting.defaultValue == false)
        #expect(BrowserPageTunables.all.contains { $0.key == "browserPage.drawKeysAtOnce" })
    }
}
