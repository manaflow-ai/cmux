@testable import CmuxNextCloudTunnel
import Foundation
import Testing

/// The opt-in Cloud Tunnel's state machine against fakes of SystemExtensions, NetworkExtension
/// and the Cloud API. The rule the user set (2026-11-03): off by default, and approval is asked
/// only when the user turns it on, never at launch.
@MainActor
@Suite struct CloudTunnelControllerTests {
    static let identifier = "com.cmuxterm.app.nightly.tunnel"
    static let wgQuick = """
        [Interface]
        PrivateKey = cHJpdmF0ZS1rZXktYnl0ZXMtMzItbG9uZy1hYWFhYWE=
        Address = 10.192.0.7/32
        [Peer]
        PublicKey = cHVibGljLWtleS1ieXRlcy0zMi1sb25nLWFhYWFhYWE=
        AllowedIPs = 10.192.0.0/20
        Endpoint = gw.example.com:51820
        """

    @MainActor final class Activator: SystemExtensionActivating {
        var requests: [String] = []
        var script: [SystemExtensionActivationEvent] = [.activated]
        /// When set, the stream stays open after the scripted events (approval pending).
        var holdOpen = false
        var pending: AsyncStream<SystemExtensionActivationEvent>.Continuation?

        func activate(identifier: String) -> AsyncStream<SystemExtensionActivationEvent> {
            requests.append(identifier)
            let (stream, continuation) = AsyncStream<SystemExtensionActivationEvent>.makeStream()
            for event in script { continuation.yield(event) }
            if holdOpen { pending = continuation } else { continuation.finish() }
            return stream
        }
    }

    @MainActor final class Manager: TunnelManaging {
        var saved = false
        var calls: [String] = []
        var installed: CloudTunnelConfiguration?
        var continuation: AsyncStream<CloudTunnelConnectionState>.Continuation?
        var startError: (any Error)?

        func loadSaved() async throws -> Bool {
            calls.append("load")
            return saved
        }

        func install(_ configuration: CloudTunnelConfiguration, providerBundleIdentifier: String) async throws {
            calls.append("install \(providerBundleIdentifier)")
            installed = configuration
            saved = true
        }

        func start() throws {
            calls.append("start")
            if let startError { throw startError }
        }

        func stop() { calls.append("stop") }

        func remove() async throws {
            calls.append("remove")
            saved = false
        }

        func states() -> AsyncStream<CloudTunnelConnectionState> {
            let (stream, continuation) = AsyncStream<CloudTunnelConnectionState>.makeStream()
            continuation.yield(.disconnected)
            self.continuation = continuation
            return stream
        }
    }

    final class Enroller: CloudTunnelEnrolling, @unchecked Sendable {
        // Safe: the tests touch it only from the main actor, one test at a time.
        var count = 0
        var result: Result<String, any Error> = .success(CloudTunnelControllerTests.wgQuick)

        func enrollBrowserPeer() async throws -> String {
            count += 1
            return try result.get()
        }
    }

    struct EnrollFailure: LocalizedError {
        var errorDescription: String? { "Sign in to cmux Cloud." }
    }

    let activator = Activator()
    let manager = Manager()
    let enroller = Enroller()

    func controller(_ availability: CloudTunnelController.Availability = .available(extensionIdentifier: identifier)) -> CloudTunnelController {
        CloudTunnelController(availability: availability, activator: activator, manager: manager, enroller: enroller)
    }

    /// Lets the state-watch task deliver what the fake manager yielded.
    func settle(_ tunnel: CloudTunnelController, until predicate: (CloudTunnelStatus) -> Bool) async {
        for _ in 0..<200 where !predicate(tunnel.status) { await Task.yield() }
    }

    @Test func isOffByDefaultAndALaunchWithTheSettingOffTouchesNothing() async {
        let tunnel = controller()
        #expect(tunnel.status == .off)
        await tunnel.restore(enabled: false)
        #expect(tunnel.status == .off)
        #expect(activator.requests.isEmpty, "no activation request while off")
        #expect(manager.calls.isEmpty, "no NetworkExtension call while off")
        #expect(enroller.count == 0)
    }

    @Test func enablingActivatesEnrollsTheBrowserPeerInstallsAndStarts() async {
        let tunnel = controller()
        await tunnel.enable()
        #expect(activator.requests == [Self.identifier])
        #expect(enroller.count == 1)
        #expect(manager.calls == ["load", "install \(Self.identifier)", "start"])
        #expect(manager.installed?.routes.map(\.description) == ["10.192.0.0/20"])
        #expect(tunnel.status == .connecting, "the initial disconnected state of a fresh start is not a failure")

        let since = Date(timeIntervalSince1970: 1_793_700_000)
        manager.continuation?.yield(.connecting)
        manager.continuation?.yield(.connected(since: since))
        await settle(tunnel) { $0 == .connected(since: since) }
        #expect(tunnel.status == .connected(since: since))
    }

    @Test func approvalIsAwaitedThenTheStartContinues() async {
        activator.script = [.needsApproval]
        activator.holdOpen = true
        let tunnel = controller()
        let enabling = Task { await tunnel.enable() }
        await settle(tunnel) { $0 == .awaitingApproval }
        #expect(tunnel.status == .awaitingApproval)
        #expect(enroller.count == 0, "no peer is enrolled before the user allows the extension")
        #expect(manager.calls.isEmpty)

        activator.pending?.yield(.activated)
        activator.pending?.finish()
        await enabling.value
        #expect(manager.calls == ["load", "install \(Self.identifier)", "start"])
    }

    @Test func aDeniedOrFailedActivationFailsWithTheSystemsReason() async {
        activator.script = [.needsApproval, .failed("The extension was not allowed.")]
        let tunnel = controller()
        await tunnel.enable()
        #expect(tunnel.status == .failed("The extension was not allowed."))
        #expect(enroller.count == 0)
        #expect(manager.calls.isEmpty)
    }

    @Test func anEnrollmentFailureFailsWithoutStartingAnything() async {
        enroller.result = .failure(EnrollFailure())
        let tunnel = controller()
        await tunnel.enable()
        #expect(tunnel.status == .failed("Sign in to cmux Cloud."))
        #expect(manager.calls == ["load"])
    }

    @Test func aLaunchWithTheSettingOnReusesTheSavedConfigurationWithoutEnrolling() async {
        manager.saved = true
        let tunnel = controller()
        await tunnel.restore(enabled: true)
        #expect(activator.requests == [Self.identifier], "a silent replace of an allowed extension")
        #expect(enroller.count == 0)
        #expect(manager.calls == ["load", "load", "start"])
    }

    @Test func aLaunchWithTheSettingOnButNoSavedConfigurationNeverAsksForApproval() async {
        let tunnel = controller()
        await tunnel.restore(enabled: true)
        #expect(activator.requests.isEmpty, "approval is asked only on an explicit turn-on")
        #expect(enroller.count == 0)
        if case .failed = tunnel.status {} else { Issue.record("expected a finish-setup status, got \(tunnel.status)") }
    }

    @Test func disablingStopsAndRemovesTheConfiguration() async {
        let tunnel = controller()
        await tunnel.enable()
        await tunnel.disable()
        #expect(manager.calls.suffix(2) == ["stop", "remove"])
        #expect(tunnel.status == .off)
        manager.continuation?.yield(.disconnected)
        await settle(tunnel) { $0 != .off }
        #expect(tunnel.status == .off, "a disconnect after turning off is not a failure")
    }

    @Test func anUnexpectedDisconnectWhileOnIsAFailure() async {
        let tunnel = controller()
        await tunnel.enable()
        manager.continuation?.yield(.connected(since: nil))
        manager.continuation?.yield(.disconnected)
        await settle(tunnel) { $0.name == "failed" }
        #expect(tunnel.status.name == "failed")
    }

    @Test func anUnavailableBuildReportsWhyAndTouchesNothing() async {
        let tunnel = controller(.unavailable("This build is not signed for system extensions."))
        await tunnel.enable()
        await tunnel.restore(enabled: true)
        await tunnel.disable()
        #expect(tunnel.status == .unavailable("This build is not signed for system extensions."))
        #expect(activator.requests.isEmpty)
        #expect(manager.calls.isEmpty)
    }

    /// Lets the follow task apply what the setting stream yielded.
    func drain(until predicate: () -> Bool) async {
        for _ in 0..<500 where !predicate() { await Task.yield() }
    }

    @Test func followingTheSettingAppliesTheLaunchValueThenEachChange() async {
        let tunnel = controller()
        let (values, setting) = AsyncStream<Bool>.makeStream()
        tunnel.follow(values)
        setting.yield(false)
        setting.yield(false)
        await drain { false }
        #expect(activator.requests.isEmpty, "a launch with the setting off touches nothing")
        #expect(manager.calls.isEmpty)

        setting.yield(true)
        await drain { manager.calls.contains("start") }
        #expect(activator.requests == [Self.identifier], "turning the setting on asks for activation")
        #expect(manager.calls == ["load", "install \(Self.identifier)", "start"])

        setting.yield(false)
        await drain { tunnel.status == .off }
        #expect(manager.calls.suffix(2) == ["stop", "remove"])
        #expect(tunnel.status == .off)
        setting.finish()
    }

    @Test func aBundleWithoutTheExtensionIsUnavailableOnceProbed() async throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-tunnel-probe-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let probe = CloudTunnelBundleProbe(bundle: try #require(Bundle(url: bundle)))
        let tunnel = CloudTunnelController(probe: probe, activator: activator, manager: manager, enroller: enroller)
        #expect(tunnel.status == .off, "the status is off until an entry point applies the probe")
        await tunnel.enable()
        #expect(tunnel.status.name == "unavailable")
        #expect(activator.requests.isEmpty)
        #expect(manager.calls.isEmpty)
    }
}
