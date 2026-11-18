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
    }
}
