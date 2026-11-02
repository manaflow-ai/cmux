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
    @Test func nativeIsTheDefaultAndZeroTurnsItOff() {
        #expect(CloudNativeFirstLauncher.choice(setting: nil) == .native)
        #expect(CloudNativeFirstLauncher.choice(setting: "1") == .native)
        #expect(CloudNativeFirstLauncher.choice(setting: "0") == .link)
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

    /// `cloud.machines`' `link_route` (#32494): the launcher each link source and choice gets, and its route.
    @Test func theAppServerLinkReportsTheRouteItLaunched() async throws {
        let link = FakeLauncher(status: "link")
        var asked = 0
        let legacy = CloudAppServerLink(appServer: false, link: link, choice: .native, native: { asked += 1; return nil }) { _ in }
        #expect(legacy.launcher == nil && legacy.route() == "legacy")
        let cmuxLink = CloudAppServerLink(appServer: true, link: link, choice: .link, native: { asked += 1; return nil }) { _ in }
        #expect(cmuxLink.launcher as? FakeLauncher === link && cmuxLink.route() == "link")
        #expect(asked == 0, "the Native route holder was made for a choice that does not use it")
        let noHolder = CloudAppServerLink(appServer: true, link: link, choice: .native, native: { asked += 1; return nil }) { _ in }
        #expect(asked == 1 && noHolder.launcher as? FakeLauncher === link)
        #expect(noHolder.route() == "link (native asked; no Native route holder for this app)")

        let native = FakeLauncher(status: "native", failure: NativeDeviceEnrollmentError.refused(400))
        var reasons = 0
        let first = CloudAppServerLink(appServer: true, link: link, choice: .native, native: { native }) { _ in reasons += 1 }
        #expect(first.launcher is CloudNativeFirstLauncher && first.route() == "native")
        #expect(try await first.launcher?.ensure(install: "i").status == "link")
        #expect(reasons == 1)
        #expect(first.route() == "link (native failed: \(NativeDeviceEnrollmentError.refused(400)))")
    }

    @Test func signedOutIsNotARouteFailure() async {
        let native = FakeLauncher(status: "native", failure: NativeDeviceEnrollmentError.signedOut)
        let link = FakeLauncher(status: "link")
        let launcher = CloudNativeFirstLauncher(native: native, link: link)
        await #expect(throws: NativeDeviceEnrollmentError.signedOut) { try await launcher.ensure(install: "i") }
        #expect(link.ensures == 0)
    }
}
