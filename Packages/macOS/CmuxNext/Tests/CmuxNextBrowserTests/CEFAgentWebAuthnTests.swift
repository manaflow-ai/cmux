import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A tab an agent drives never completes a passkey ceremony (plans/cmux-next/passkeys.md 3.5; Fable's
/// passkey review D5, 2026-11-17): the fork refuses every WebAuthn create and get of a tab in
/// CMUX_WEBAUTHN_MODE_REFUSE before an authenticator is asked, so an agent's click shows no Touch ID
/// sheet. The app never set that mode (no shim binding), so an agent-driven tab could open a real
/// Touch ID sheet over the person's work. The mode is set when a live tab becomes agent-driven, and
/// for a tab marked before its browser exists, when the browser attaches, before its first load.
extension CEFSparePageSuites {
    @MainActor @Suite struct CEFAgentWebAuthnTests {
        typealias Fixture = CEFSparePageSuites.CEFSparePageTests

        @Test func aLiveTabAnAgentTakesRefusesWebAuthn() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let (_, tab, _) = try Fixture.liveHost(runtime)
            #expect(SpareSpy.webAuthnModes.isEmpty, "a person's tab keeps Chromium's passkeys")

            tab.markAgentDriven()
            #expect(SpareSpy.webAuthnModes.map(\.browser) == [10])
            #expect(SpareSpy.webAuthnModes.map(\.mode) == [1], "CMUX_WEBAUTHN_MODE_REFUSE")
            tab.markAgentDriven()
            #expect(SpareSpy.webAuthnModes.count == 1, "set once")
        }

        @Test func aTabMarkedBeforeItsBrowserExistsRefusesBeforeItsFirstLoad() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.markAgentDriven()
            tab.load(URL(string: "https://github.com/sessions/sudo")!)
            host.add(tab)
            host.present(tab, in: container)
            host.createDeferred()
            #expect(SpareSpy.webAuthnModes.isEmpty, "no browser yet")

            SpareSpy.windows[10] = 1
            runtime.handle(.afterCreated(browser: 10, request: try #require(runtime.pendingWindows.keys.first), window: 1))
            #expect(SpareSpy.webAuthnModes.map(\.browser) == [10])
            let refused = try #require(SpareSpy.log.firstIndex(of: "webauthn 10 1"))
            if let load = SpareSpy.log.firstIndex(of: "load 10") {
                #expect(refused < load, "refused before the page loads: \(SpareSpy.log)")
            }
        }

        /// Cloudflare's "Verify with a security key" (2026-11-20): an agent drove the tab to the 2FA step and handed it
        /// over; the person's touch could not count, because the tab stayed refused for good and Cloudflare showed
        /// "Security key verification did not finish" for every try, theirs included (a visible tab: NotAllowedError
        /// in 6 ms, before any authenticator). Chrome runs the person's request. The person's own click or key in the
        /// page (the app's input hook, which agent input through DevTools never reaches) takes the page over.
        @Test func thePersonsClickInAnAgentTabLetsTheirSecurityKeyRun() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let (_, tab, _) = try Fixture.liveHost(runtime)
            tab.markAgentDriven()
            #expect(SpareSpy.webAuthnModes.map(\.mode) == [1])

            runtime.windowRequests.linkClicks.record(.leftMouseDown, on: 10, button: 0, flags: [], timestamp: 1)
            #expect(SpareSpy.webAuthnModes.map(\.browser) == [10, 10])
            #expect(SpareSpy.webAuthnModes.map(\.mode) == [1, 0], "CMUX_WEBAUTHN_MODE_ALLOW after the person's click")
            runtime.windowRequests.linkClicks.record(.leftMouseUp, on: 10, button: 0, flags: [], timestamp: 1)
            runtime.windowRequests.linkClicks.record(.keyDown, on: 10, button: 0, flags: [], timestamp: 2)
            #expect(SpareSpy.webAuthnModes.count == 2, "set once")
        }

        /// The agent's next click, keys or navigation in the page refuses again: the hand-over was the person's.
        @Test func theAgentsNextActionRefusesAgain() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let (_, tab, _) = try Fixture.liveHost(runtime)
            tab.markAgentDriven()
            runtime.windowRequests.linkClicks.record(.leftMouseDown, on: 10, button: 0, flags: [], timestamp: 1)
            tab.refuseWebAuthnForAgent()
            #expect(SpareSpy.webAuthnModes.map(\.mode) == [1, 0, 1])
            tab.refuseWebAuthnForAgent()
            #expect(SpareSpy.webAuthnModes.count == 3, "refused once")
            // And the person can take it again.
            runtime.windowRequests.linkClicks.record(.keyDown, on: 10, button: 0, flags: [], timestamp: 2)
            #expect(SpareSpy.webAuthnModes.map(\.mode) == [1, 0, 1, 0])
        }

        /// The passkey hand-off (`cmux browser passkey`, the Chief's escalate_auth): the person's click on the request
        /// or the tab already in front of them hands the page over before the trigger clicks its button.
        @Test func aPasskeyHandOverAllowsTheCeremony() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let (_, tab, _) = try Fixture.liveHost(runtime)
            tab.markAgentDriven()
            tab.allowWebAuthnForPerson()
            #expect(SpareSpy.webAuthnModes.map(\.mode) == [1, 0])
            tab.allowWebAuthnForPerson()
            #expect(SpareSpy.webAuthnModes.count == 2)
        }

        /// A person's own tab never had a mode set: their input and an agent action that never marked it change nothing.
        @Test func aPersonsOwnTabMakesNoCalls() throws {
            let (runtime, root) = try Fixture.runtime()
            defer { Fixture.tearDown(runtime, root) }
            let (_, tab, _) = try Fixture.liveHost(runtime)
            runtime.windowRequests.linkClicks.record(.leftMouseDown, on: 10, button: 0, flags: [], timestamp: 1)
            tab.allowWebAuthnForPerson()
            tab.refuseWebAuthnForAgent()
            #expect(SpareSpy.webAuthnModes.isEmpty)
        }
    }
}
