import Foundation
import Testing
@testable import CmuxMobileChief

/// Every Call entry point names its Chief; the launcher hands it to the shell unchanged.
@MainActor
@Suite struct ChiefCallLauncherTests {
    static func chief(_ id: String) -> ChiefSession {
        ChiefSession(backend: ChiefOfflineBackend(), identity: ChiefIdentity(chiefID: id), outbox: ChiefOutbox(file: nil))
    }

    @Test func aCallGoesToTheChiefNamed() {
        let launcher = ChiefCallLauncher()
        var called: [ChiefSession?] = []
        launcher.handler = { called.append($0) }
        let atlas = Self.chief("agent_atlas")
        launcher.call(atlas)
        launcher.call()
        #expect(called.count == 2)
        #expect(called.first.flatMap { $0 } === atlas)
        #expect(called.last.flatMap { $0 } == nil, "no Chief named: the default Chief")
    }

    /// A cold launch: the call waits for the shell and keeps its Chief.
    @Test func aCallAskedBeforeTheShellKeepsItsChief() {
        let launcher = ChiefCallLauncher(now: { Date(timeIntervalSince1970: 1_000) })
        let atlas = Self.chief("agent_atlas")
        launcher.call(atlas)
        var called: [ChiefSession?] = []
        launcher.handler = { called.append($0) }
        #expect(called.count == 1)
        #expect(called.first.flatMap { $0 } === atlas)
    }
}
