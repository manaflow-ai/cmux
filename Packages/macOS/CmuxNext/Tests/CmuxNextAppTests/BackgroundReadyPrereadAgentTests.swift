@testable import CmuxNextQuit
import ServiceManagement
import Testing

/// The login-time pre-read agent (`app.backgroundReady` = `warmAtLogin`; Leo 2026-11-18, ask-b2b0f899c1): it is
/// registered only when asked, unregistered when the setting moves away, left alone when already as asked, and a
/// build without the reader says so instead of registering anything.
@MainActor
struct BackgroundReadyPrereadAgentTests {
    final class Fake {
        var status: SMAppService.Status
        var statusAfterRegister: SMAppService.Status = .enabled
        var registers = 0
        var unregisters = 0
        var opened = 0
        init(_ status: SMAppService.Status) { self.status = status }
    }

    private static func agent(_ fake: Fake, bundled: Bool = true) -> BackgroundReadyPrereadAgent {
        BackgroundReadyPrereadAgent(
            isBundled: { bundled },
            service: .init(status: { fake.status },
                           register: { fake.registers += 1; fake.status = fake.statusAfterRegister },
                           unregister: { fake.unregisters += 1; fake.status = .notRegistered },
                           openLoginItems: { fake.opened += 1 }))
    }

    @Test func offWithNothingRegisteredDoesNothing() {
        let fake = Fake(.notRegistered)
        #expect(Self.agent(fake).apply(registers: false) == .unchanged)
        #expect(fake.registers == 0 && fake.unregisters == 0)
    }

    @Test func warmAtLoginRegistersOnceAndThenLeavesItAlone() {
        let fake = Fake(.notRegistered)
        #expect(Self.agent(fake).apply(registers: true) == .registered)
        #expect(Self.agent(fake).apply(registers: true) == .unchanged)
        #expect(fake.registers == 1)
    }

    @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
    func switchingAwayUnregisters(_ status: SMAppService.Status) {
        let fake = Fake(status)
        #expect(Self.agent(fake).apply(registers: false) == .unregistered)
        #expect(fake.unregisters == 1)
        #expect(Self.agent(fake).apply(registers: false) == .unchanged)
    }

    @Test func aBuildWithoutTheReaderRegistersNothing() {
        let fake = Fake(.notFound)
        #expect(Self.agent(fake, bundled: false).apply(registers: true) == .notInBuild)
        #expect(fake.registers == 0)
    }

    @Test func approvalOpensLoginItemsOnlyRightAfterRegistering() {
        let fake = Fake(.notRegistered)
        fake.statusAfterRegister = .requiresApproval
        #expect(Self.agent(fake).apply(registers: true) == .requiresApproval)
        #expect(fake.opened == 1)
        // The next launch, still waiting for approval: no second System Settings window.
        #expect(Self.agent(fake).apply(registers: true) == .requiresApproval)
        #expect(fake.opened == 1 && fake.registers == 1)
    }
}
