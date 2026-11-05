import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// Leo, 2026-11-05, on a new chat tab of `cmux DEV cloud-firstsend` on cosmic-gray whose machine
/// picker read "cosmic-gray · Local": "why does it even say this "does nto run here"??". #35284
/// put the Cloud install id under the selected backend's folder (`cloud-next/<namespace>/device-id`),
/// and a tagged build always selects one (Rust's `legacy_storage` is false for every tagged
/// bundle), so the build's next launch named this Mac with a new `install:<id>`. Its tabs, saved
/// with the old one, then read as another machine's: "This chat belongs to another machine, so it
/// does not run here."
@MainActor struct AgentTabsAfterACloudBackendSwitchTests {
    /// A tagged build's Cloud selection: its own backend namespace (`staging-2`), no legacy storage.
    private static func tagged(_ bundle: String) -> CloudConfiguration {
        let origin = URL(string: "https://backend.standin.invalid")!
        let selection = CloudRuntimeSelection(name: "staging", apiOrigin: origin, authWebOrigin: origin, vmOrigin: origin,
            platformOrigin: origin, mobileOrigin: origin, deviceHubOrigin: origin, shareRoomOrigin: origin, shareApiOrigin: origin,
            stackOrigin: origin, stackProjectId: "staging-project", stackClientKey: "staging-key", bundleId: bundle,
            mutable: true, authNamespace: "staging-2", legacyStorage: false)
        return CloudConfiguration.from(selection: selection, bundleID: bundle, bundled: [:], process: [:], isDebugBuild: true)
    }

    /// The build's Cloud folder (`~/Library/Application Support/cmux/<bundle>/cloud-next`) holding
    /// the `device-id` its launches before #35284 wrote, under a bundle id of this test's own.
    private static func buildFolder() throws -> (bundle: String, folder: URL) {
        let bundle = "com.cmuxterm.app.debug.next.chatmachine\(UUID().uuidString.prefix(8).lowercased())"
        let folder = CloudPaths.standard(bundleID: bundle).root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mac-before\n".utf8).write(to: folder.appendingPathComponent("device-id"))
        return (bundle, folder)
    }

    private static func cloud(_ configuration: CloudConfiguration) -> CloudService {
        CloudService(machines: MachineRegistry(local: DaemonService()), isDebugBuild: true,
                     mainWork: MainWorkScheduler(budget: MainFrameBudget()), work: BackgroundWork(),
                     loginKeychain: LoginKeychain(), configuration: configuration)
    }

    @Test func aTabThisMacSavedIsStillThisMacsOnceATaggedBuildSelectsACloudBackend() throws {
        let (bundle, folder) = try Self.buildFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let cloud = Self.cloud(Self.tagged(bundle))

        // This Mac is the Mac its tabs were saved on, whichever Cloud backend this launch selected.
        #expect(try cloud.localDeviceID() == "mac-before")

        // The New Tab page of "workspace-1", saved before the switch, opens here: no "belongs to another machine".
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        tabs.resolveLocalHost = { (try? cloud.localDeviceID()).map(AgentSessionRef.host(installID:)) }
        let saved = AgentSessionRef(host: AgentSessionRef.host(installID: "mac-before"), hostName: "cosmic-gray")
        #expect(AgentPaneHostKind(saved, localHost: tabs.localHost, chiefHost: nil, listedHere: true) == .local)
    }

    /// A tab a launch on the selected backend saved (under that backend's id, before this fix) is this
    /// Mac's too; the tunnel keeps the backend's id; another Mac's tab still is not this Mac's.
    @Test func aTabSavedUnderABackendsIDIsThisMacsAndAnotherMacsIsNot() throws {
        let (bundle, folder) = try Self.buildFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let backend = folder.appendingPathComponent("staging-2", isDirectory: true)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        try Data("mac-staging\n".utf8).write(to: backend.appendingPathComponent("device-id"))
        let cloud = Self.cloud(Self.tagged(bundle))
        #expect(try cloud.localDeviceID() == "mac-before")
        #expect(try cloud.installIDs.backend.loadNow() == "mac-staging", "the tunnel enrolls the selected backend's id")

        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        tabs.resolveLocalHost = { (try? cloud.localDeviceID()).map(AgentSessionRef.host(installID:)) }
        tabs.resolveFormerLocalHosts = { Set(cloud.installIDs.backendIDs().map(AgentSessionRef.host(installID:))) }
        let staging = AgentSessionRef(host: AgentSessionRef.host(installID: "mac-staging"), hostName: "cosmic-gray")
        #expect(tabs.hostKind(staging, listedHere: true) == .local)
        // Only a tab this Mac's tree lists: another machine's store naming that id is that machine's.
        #expect(tabs.hostKind(staging, listedHere: false) == .remote)
        let otherMac = AgentSessionRef(host: AgentSessionRef.host(installID: "mac-other"), hostName: "big-red")
        #expect(tabs.hostKind(otherMac, listedHere: true) == .remote)
    }

    /// The banner a tab of another machine still shows names that machine, never "another machine".
    @Test func theBannerNamesTheMachineTheChatBelongsTo() {
        let elsewhere = AgentRemoteStartRefusal(code: AgentRemoteStartRefusal.hostMismatchCode, machine: "big-red").userMessage
        #expect(elsewhere == "This chat belongs to big-red, so it does not run on this Mac.")
        let listed = AgentRemoteStartRefusal(code: AgentRemoteStartRefusal.listedElsewhereCode, machine: "cosmic-gray").userMessage
        #expect(listed == "This chat belongs to this Mac, so it does not run on cosmic-gray.")
    }
}
