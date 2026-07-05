import CmuxMobileDiagnostics
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellDiagnosticsEventLogTests {
    @Test func diagnosticsEventLogIsStoreScopedAcrossRecreationAndSignOut() async throws {
        let firstStore = MobileShellComposite.preview()
        let recreatedStore = MobileShellComposite.preview()
        let firstLog = try #require(firstStore.diagnosticsEventLog)
        let recreatedLog = try #require(recreatedStore.diagnosticsEventLog)

        await firstLog.record("conn.error", fields: ["message": "previous account"])

        #expect(await firstLog.snapshot().map(\.name) == ["conn.error"])
        #expect(await recreatedLog.snapshot().isEmpty)

        firstStore.signOut()

        let resetLog = try #require(firstStore.diagnosticsEventLog)
        #expect(await resetLog.snapshot().isEmpty)
        #expect(await firstLog.snapshot().map(\.name) == ["conn.error"])
    }
}
