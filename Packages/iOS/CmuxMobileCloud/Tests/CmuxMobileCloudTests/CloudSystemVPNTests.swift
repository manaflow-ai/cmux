import Foundation
import Testing
@testable import CmuxMobileCloud

@MainActor
@Suite struct CloudSystemVPNTests {
    @Test func openingCloudLoadsStatusWithoutEnrollingOrPrompting() async {
        let service = FakeCloudVMService()
        let manager = FakeSystemVPNManager()
        let vpn = make(service, manager)
        vpn.setScope("account/team")
        await vpn.waitForPendingOperation()
        #expect(manager.refreshes == ["account/team"])
        #expect(service.calls.enroll.isEmpty)
        #expect(manager.configurations.isEmpty)
        #expect(vpn.phase == .off)
    }

    @Test func optInUsesSeparatePersistentIdentityAndOSStatus() async throws {
        let service = FakeCloudVMService()
        let manager = FakeSystemVPNManager()
        let terminalStore = InMemoryCloudDeviceIdentityStore()
        let systemStore = InMemoryCloudDeviceIdentityStore()
        let terminalIdentity = try await CloudDeviceIdentityResolver(store: terminalStore).resolve()
        let vpn = make(service, manager, store: systemStore)
        vpn.setScope("account/team")
        await vpn.waitForPendingOperation()
        vpn.enable()
        vpn.enable()
        await vpn.waitForPendingOperation()
        #expect(service.calls.enroll.count == 1)
        #expect(service.calls.enroll.first?.publicKey != terminalIdentity.keyPair.publicKey)
        #expect(service.calls.enroll.first?.fingerprint != terminalIdentity.fingerprint)
        #expect(service.calls.enroll.first?.purpose == .browser)
        #expect(vpn.phase == .connecting)
        manager.report(.connected)
        #expect(vpn.phase == .connected)
        manager.report(.off)
        #expect(vpn.phase == .off)
        vpn.enable()
        await vpn.waitForPendingOperation()
        #expect(service.calls.enroll[0].publicKey == service.calls.enroll[1].publicKey)
        #expect(service.calls.enroll[0].fingerprint == service.calls.enroll[1].fingerprint)
    }

    @Test func deniedApprovalOffersExplicitRetryWithoutAutomaticPrompt() async {
        let service = FakeCloudVMService()
        let manager = FakeSystemVPNManager()
        manager.failure = .permissionRequired
        let vpn = make(service, manager)
        vpn.setScope("account/team")
        await vpn.waitForPendingOperation()
        vpn.enable()
        await vpn.waitForPendingOperation()
        #expect(vpn.phase == .failed(.permissionRequired))
        #expect(CloudSystemVPNError.permissionRequired.offersSettingsRecovery)
        #expect(manager.configurations.count == 1)
        manager.report(.off)
        await vpn.refresh()
        #expect(vpn.phase == .failed(.permissionRequired))
        #expect(manager.configurations.count == 1)
        manager.failure = nil
        vpn.enable()
        await vpn.waitForPendingOperation()
        #expect(manager.configurations.count == 2)
        #expect(vpn.phase == .connecting)
    }

    @Test func enrollmentFailureDoesNotOfferSettingsBeforeConsent() async {
        let service = FakeCloudVMService()
        service.enrollment = .failure(CloudAPIError.httpStatus(400, message: "deviceId is required.", action: nil))
        let manager = FakeSystemVPNManager()
        let vpn = make(service, manager)
        vpn.setScope("account/team")
        await vpn.waitForPendingOperation()
        vpn.enable()
        await vpn.waitForPendingOperation()
        #expect(vpn.phase == .failed(.enrollment))
        #expect(!CloudSystemVPNError.enrollment.offersSettingsRecovery)
        #expect(manager.configurations.isEmpty)
        service.enrollment = .success(Fixtures.enrollment)
        vpn.enable()
        await vpn.waitForPendingOperation()
        #expect(manager.configurations.count == 1)
        #expect(vpn.phase == .connecting)
    }

    @Test func signOutRemovesInheritedVPNEvenBeforeCloudWasOpened() async {
        let service = FakeCloudVMService()
        let manager = FakeSystemVPNManager()
        manager.report(.connected)
        let vpn = make(service, manager)
        vpn.setScope(nil)
        await vpn.waitForPendingOperation()
        #expect(manager.removals == [true])
        #expect(vpn.phase == .off)
        #expect(service.calls.enroll.isEmpty)
    }

    @Test func accountChangeFencesAnApprovalStillOnScreen() async {
        let service = FakeCloudVMService()
        let manager = FakeSystemVPNManager()
        manager.shouldSuspendStart = true
        let vpn = make(service, manager)
        vpn.setScope("first")
        await vpn.waitForPendingOperation()
        vpn.enable()
        await manager.waitForStart()
        vpn.setScope("second")
        manager.finishStart()
        await vpn.waitForPendingOperation()
        #expect(manager.removals == [true])
        #expect(manager.refreshes == ["first", "second"])
        #expect(vpn.phase == .off)
    }

    @Test func cancelDuringConsentStopsAfterSaveFinishes() async {
        let service = FakeCloudVMService()
        let manager = FakeSystemVPNManager()
        manager.shouldSuspendStart = true
        let vpn = make(service, manager)
        vpn.setScope("first")
        await vpn.waitForPendingOperation()
        vpn.enable()
        await manager.waitForStart()
        vpn.disable()
        manager.finishStart()
        await vpn.waitForPendingOperation()
        #expect(manager.removals == [false])
        #expect(vpn.phase == .off)
    }

    private func make(
        _ service: FakeCloudVMService, _ manager: FakeSystemVPNManager,
        store: InMemoryCloudDeviceIdentityStore = InMemoryCloudDeviceIdentityStore()
    ) -> CloudSystemVPNController {
        CloudSystemVPNController(service: service, identityStore: store, manager: manager, deviceName: "Phone")
    }
}

@MainActor
private final class FakeSystemVPNManager: CloudSystemVPNManaging {
    var phase: CloudSystemVPNPhase = .off
    var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)?
    var refreshes: [String] = []
    var configurations: [String] = []
    var removals: [Bool] = []
    var failure: CloudSystemVPNError?
    var shouldSuspendStart = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func refresh(scope: String) async throws { refreshes.append(scope) }
    func installAndStart(configuration: String, scope: String) async throws {
        configurations.append(configuration)
        if let failure { throw failure }
        if shouldSuspendStart {
            await withCheckedContinuation { continuation in
                resume = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        report(.connecting)
    }
    func stop(removeConfiguration: Bool) async throws {
        removals.append(removeConfiguration)
        report(.off)
    }
    func report(_ value: CloudSystemVPNPhase) { phase = value; onPhaseChange?(value) }
    func waitForStart() async {
        if resume != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finishStart() { resume?.resume(); resume = nil }
}
