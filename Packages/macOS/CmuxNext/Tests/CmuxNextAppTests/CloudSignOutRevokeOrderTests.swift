import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// #35682: sign-out erased the persisted peer tails (an acpmux child process with no deadline)
/// before it revoked the WireGuard peer and the install, so a slow or hung erase held back
/// credential revocation. The revokes now run first and the erase after them.
@MainActor struct CloudSignOutRevokeOrderTests {
    /// A Cloud selection of this test's own: its own bundle id and storage, an origin that never answers.
    private static func configuration(_ bundle: String) -> CloudConfiguration {
        let origin = URL(string: "https://backend.standin.invalid")!
        let selection = CloudRuntimeSelection(name: "staging", apiOrigin: origin, authWebOrigin: origin, vmOrigin: origin,
            platformOrigin: origin, mobileOrigin: origin, deviceHubOrigin: origin, shareRoomOrigin: origin, shareApiOrigin: origin,
            stackOrigin: origin, stackProjectId: "signout-project", stackClientKey: "signout-key", bundleId: bundle,
            mutable: true, authNamespace: "signout", legacyStorage: false)
        return CloudConfiguration.from(selection: selection, bundleID: bundle, bundled: [:], process: [:], isDebugBuild: true)
    }

    @Test func aHungPeerTailEraseDoesNotHoldBackTheTunnelRevoke() async throws {
        let bundle = "com.cmuxterm.app.debug.next.signout\(UUID().uuidString.prefix(8).lowercased())"
        let root = CloudPaths.standard(bundleID: bundle).root
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let cloud = CloudService(machines: MachineRegistry(local: DaemonService()), isDebugBuild: true,
                                 mainWork: MainWorkScheduler(budget: MainFrameBudget()), work: BackgroundWork(),
                                 loginKeychain: LoginKeychain(), configuration: Self.configuration(bundle))
        let hub = CloudTunnelHub(api: cloud.api, paths: cloud.paths,
                                 binary: URL(fileURLWithPath: "/nonexistent/cmux-tui"), deviceName: "signout-test")
        cloud.hub = hub

        // The erase starts, reports whether the tunnel was already revoked, then hangs until released.
        let (entered, enteredContinuation) = AsyncStream<Bool>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        cloud.clearPeerTails = { _, _ in
            enteredContinuation.yield(await hub.isRevoked)
            for await _ in release { break }
        }

        let signOut = Task { await cloud.signOut() }
        var revokedBeforeErase: Bool?
        for await revoked in entered {
            revokedBeforeErase = revoked
            break
        }
        #expect(revokedBeforeErase == true, "sign-out must revoke the WireGuard peer before it erases peer tails")
        #expect(await hub.isRevoked)

        releaseContinuation.yield(())
        releaseContinuation.finish()
        await signOut.value
    }
}
