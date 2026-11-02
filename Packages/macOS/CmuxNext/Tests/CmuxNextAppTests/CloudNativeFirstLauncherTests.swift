@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextDaemon
import Testing

@MainActor
private final class FakeLauncher: CloudLinkLaunching {
    var failure: (any Error)?
    var ensures = 0, stops = 0, archives = 0
    let status: String
    init(status: String, failure: (any Error)? = nil) { self.status = status; self.failure = failure }
    func ensure(install: String) async throws -> CloudLinkLauncher.Ensured {
        ensures += 1
        if let failure { throw failure }
        return CloudLinkLauncher.Ensured(status: status, pid: 1)
    }
    func stop(install: String?) async { stops += 1 }
    func archive(install: String?) async { archives += 1 }
}

@MainActor
struct CloudNativeFirstLauncherTests {
    @Test func nonProductionDefaultsToNativeAndProductionToCmuxLink() {
        #expect(CloudService.nativeLinkChoice(production: false, setting: nil) == .native)
        #expect(CloudService.nativeLinkChoice(production: true, setting: nil) == .link)
        #expect(CloudService.nativeLinkChoice(production: false, setting: "0") == .link)
        #expect(CloudService.nativeLinkChoice(production: true, setting: "1") == .native)
    }

    @Test func aWorkingNativeRouteIsUsed() async throws {
        let native = FakeLauncher(status: "native"), link = FakeLauncher(status: "link")
        let launcher = CloudNativeFirstLauncher(native: native, link: link)
        #expect(try await launcher.ensure(install: "i").status == "native")
        #expect(link.ensures == 0)
    }

    @Test func aFailedNativeRouteFallsBackToCmuxLinkUntilSignOut() async throws {
        let native = FakeLauncher(status: "native", failure: NativeDeviceEnrollmentError.refused(400))
        let link = FakeLauncher(status: "link")
        var reasons: [String] = []
        let launcher = CloudNativeFirstLauncher(native: native, link: link) { reasons.append(String(describing: $0)) }
        #expect(try await launcher.ensure(install: "i").status == "link")
        #expect(try await launcher.ensure(install: "i").status == "link")
        #expect(native.ensures == 1)
        #expect(reasons.count == 1)
        await launcher.stop(install: "i")
        #expect(link.stops == 1 && native.stops == 0)
        // Sign-out clears the fallback: the next sign-in tries Native again.
        await launcher.archive(install: "i")
        native.failure = nil
        #expect(try await launcher.ensure(install: "i").status == "native")
    }

    @Test func signedOutIsNotARouteFailure() async {
        let native = FakeLauncher(status: "native", failure: NativeDeviceEnrollmentError.signedOut)
        let link = FakeLauncher(status: "link")
        let launcher = CloudNativeFirstLauncher(native: native, link: link)
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await launcher.ensure(install: "i") }
        #expect(link.ensures == 0)
    }
}
