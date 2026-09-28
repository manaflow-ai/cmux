import Foundation
import Testing
@testable import CmuxMobileCloud

/// Scripted Network Extension boundary.
@MainActor
final class FakeSystemVPNManager: CloudSystemVPNManaging {
    var isAvailable = true
    var phase: CloudSystemVPNPhase = .off
    var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)?
    var installed: [(configuration: String, scope: String)] = []
    var stops: [Bool] = []
    var refreshedScopes: [String] = []
    var installFailure: CloudSystemVPNError?
    /// The phase iOS reports once a start is requested.
    var phaseAfterStart: CloudSystemVPNPhase = .connecting

    func refresh(scope: String) async throws { refreshedScopes.append(scope) }

    func installAndStart(configuration: String, scope: String) async throws {
        if let installFailure { throw installFailure }
        installed.append((configuration, scope))
        phase = phaseAfterStart
    }

    func stop(removeConfiguration: Bool) async throws {
        stops.append(removeConfiguration)
        phase = .off
    }

    /// Simulates iOS reporting a status change on its own.
    func report(_ phase: CloudSystemVPNPhase) {
        self.phase = phase
        onPhaseChange?(phase)
    }
}

@MainActor
@Suite struct CloudSystemVPNTests {
    private struct Rig {
        let service = FakeCloudVMService()
        let store = InMemoryCloudDeviceIdentityStore()
        let manager = FakeSystemVPNManager()
        let controller: CloudSystemVPNController

        @MainActor init() {
            controller = CloudSystemVPNController(
                service: service,
                identityStore: store,
                manager: manager,
                deviceName: "Aziz's iPhone"
            )
        }
    }

    private func signedIn(_ rig: Rig, scope: String = "user-1/team-1") async {
        rig.controller.setScope(scope)
        await rig.controller.waitForPendingOperation()
    }

    @Test func enablingEnrollsAPrivateBrowserPeerWithItsOwnKey() async throws {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        #expect(rig.controller.phase == .preparing)
        await rig.controller.waitForPendingOperation()

        let enroll = try #require(rig.service.calls.enroll.first)
        #expect(enroll.purpose == .browser)
        #expect(enroll.deviceName == "Aziz's iPhone")
        // Filed under the same device as the terminal tunnel...
        guard case .found(let identity) = await rig.store.read() else {
            Issue.record("device identity was not persisted")
            return
        }
        #expect(enroll.fingerprint == identity.fingerprint)
        // ...but as a separate peer: the terminal tunnel's key never travels
        // for the VPN, so the two peers never contend for one key.
        #expect(enroll.publicKey != identity.keyPair.publicKey)

        let install = try #require(rig.manager.installed.first)
        #expect(install.scope == "user-1/team-1")
        #expect(!install.configuration.contains(identity.keyPair.privateKey))
        #expect(install.configuration.contains("PrivateKey = "))
        #expect(install.configuration.contains("AllowedIPs = 10.0.0.0/8, fd00::/8"))
        #expect(rig.controller.phase == .connecting)
    }

    @Test func eachEnableMintsAFreshKey() async throws {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.controller.disable()
        await rig.controller.waitForPendingOperation()
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        let keys = rig.service.calls.enroll.map(\.publicKey)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2)
    }

    @Test func aPublicRouteIsRefusedBeforeAnythingIsSaved() async {
        let rig = Rig()
        var enrollment = Fixtures.enrollment
        enrollment.routes = ["0.0.0.0/0"]
        rig.service.enrollment = .success(enrollment)
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.installed.isEmpty)
        #expect(rig.controller.phase == .failed(.configuration))
    }

    @Test func enrollmentFailureIsReportedAsEnrollment() async {
        let rig = Rig()
        rig.service.enrollment = .failure(CloudAPIError.httpStatus(500, message: nil, action: nil))
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.installed.isEmpty)
        #expect(rig.controller.phase == .failed(.enrollment))
        #expect(rig.controller.phase != .off)
    }

    @Test func aDeclinedConsentKeepsItsRecoveryState() async {
        let rig = Rig()
        rig.manager.installFailure = .permissionRequired
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.controller.phase == .failed(.permissionRequired))

        // iOS reports the VPN as off right after the declined prompt; the
        // failure (and its retry) must stay on screen.
        rig.manager.report(.off)
        #expect(rig.controller.phase == .failed(.permissionRequired))
    }

    @Test func statusChangesFromSettingsAreMirrored() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()

        rig.manager.report(.connected)
        #expect(rig.controller.phase == .connected)
        #expect(rig.controller.phase.isRequestedOn)
        rig.manager.report(.off)
        #expect(rig.controller.phase == .off)
        #expect(!rig.controller.phase.isRequestedOn)
    }

    @Test func disablingKeepsTheSavedVPN() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.controller.disable()
        #expect(rig.controller.phase == .disconnecting)
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [false])
        #expect(rig.controller.phase == .off)
    }

    @Test func signingOutRemovesTheVPN() async {
        let rig = Rig()
        await signedIn(rig)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        rig.controller.setScope(nil)
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [true])
        #expect(rig.controller.phase == .off)
    }

    @Test func switchingAccountsRemovesTheOldAccountsVPNFirst() async {
        let rig = Rig()
        await signedIn(rig, scope: "user-1/team-1")
        rig.controller.setScope("user-2/team-9")
        await rig.controller.waitForPendingOperation()

        #expect(rig.manager.stops == [true])
        #expect(rig.manager.refreshedScopes == ["user-1/team-1", "user-2/team-9"])
    }

    @Test func theFirstSignedInScopeDoesNotRemoveAnything() async {
        let rig = Rig()
        await signedIn(rig)
        #expect(rig.manager.stops.isEmpty)
        #expect(rig.manager.refreshedScopes == ["user-1/team-1"])
    }

    @Test func enablingWithoutAnAccountFailsWithoutCallingCloud() async {
        let rig = Rig()
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.service.calls.enroll.isEmpty)
        #expect(rig.controller.phase == .failed(.enrollment))
    }

    @Test func anUnavailableDeviceNeverEnrolls() async {
        let rig = Rig()
        rig.manager.isAvailable = false
        await signedIn(rig)
        #expect(!rig.controller.isAvailable)
        rig.controller.enable()
        await rig.controller.waitForPendingOperation()
        #expect(rig.service.calls.enroll.isEmpty)
        #expect(rig.controller.phase == .failed(.unavailable))
    }

    @Test func routePolicyAdmitsOnlyPrivateRanges() {
        let policy = CloudVPNRoutePolicy()
        #expect(policy.permits("10.0.0.0/8"))
        #expect(policy.permits("10.100.0.0/16"))
        #expect(policy.permits("172.16.0.0/12"))
        #expect(policy.permits("192.168.1.0/24"))
        #expect(policy.permits("100.64.0.7/32"))
        #expect(policy.permits("fd7a:7570:6c6b::/64"))
        #expect(policy.permits(" fd00::/8 "))

        #expect(!policy.permits("0.0.0.0/0"))
        #expect(!policy.permits("8.8.8.8/32"))
        #expect(!policy.permits("10.0.0.0/7"))
        #expect(!policy.permits("172.32.0.0/16"))
        #expect(!policy.permits("100.128.0.0/10"))
        #expect(!policy.permits("::/0"))
        #expect(!policy.permits("2600:1f18::1/128"))
        #expect(!policy.permits("10.0.0.1"))
        #expect(!policy.permits("10.0.0.0/33"))
        #expect(!policy.permits("not-an-address/8"))
    }
}
