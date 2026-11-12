import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
struct MobileWorkspaceSnapshotStoreTests {
    @Test
    func snapshotsRoundTripWithoutAuthorityOrTerminalOutput() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests.\(UUID().uuidString)")!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        var workspace = MobileWorkspacePreview(
            id: "workspace-a",
            macDeviceID: "mac-a",
            name: "Mario",
            terminals: [MobileTerminalPreview(id: "terminal-a", name: "codex")]
        )
        workspace.remoteWorkspaceID = "remote-workspace-a"
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            displayName: "Build Mac",
            workspaces: [workspace],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true,
            actionCapabilities: MobileWorkspaceActionCapabilities(
                supportsWorkspaceActions: true,
                supportsWorkspaceMetadata: true
            )
        )

        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let restored = store.load(userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(restored?.workspaces == [workspace])
        #expect(restored?.workspaces.first?.remoteWorkspaceID == "remote-workspace-a")
        #expect(restored?.status == .reconnecting)
        #expect(restored?.workspaceSnapshotIsAuthoritative == false)
        #expect(restored?.actionCapabilities == MobileWorkspaceActionCapabilities.none)
        #expect(store.load(userID: "user-b", teamID: "team-a", pairing: pairing) == nil)
        #expect(store.load(userID: "user-a", teamID: "team-b", pairing: pairing) == nil)
    }

    @Test
    func loadAllReturnsOnlyTheCurrentAccountAndTeamScope() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let nightly = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let stable = MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        let other = MacPairingKey(macDeviceID: "mac-b", instanceTag: "nightly")

        func state(for pairing: MacPairingKey) -> MacWorkspaceState {
            MacWorkspaceState(
                macDeviceID: pairing.canonicalMacDeviceID,
                instanceTag: pairing.normalizedInstanceTag,
                workspaces: [MobileWorkspacePreview(
                    id: .init(rawValue: pairing.pairingID + "-workspace"),
                    macDeviceID: pairing.canonicalMacDeviceID,
                    name: pairing.pairingID,
                    terminals: []
                )],
                status: .connected,
                workspaceSnapshotIsAuthoritative: true
            )
        }

        await store.save(state: state(for: nightly), userID: "user-a", teamID: "team-a", pairing: nightly)
        await store.save(state: state(for: stable), userID: "user-a", teamID: "team-a", pairing: stable)
        await store.save(state: state(for: other), userID: "user-b", teamID: "team-a", pairing: other)

        let loaded = await store.loadAll(userID: "user-a", teamID: "team-a")
        #expect(Set(loaded.map(\.0)) == [nightly, stable])
        #expect(loaded.allSatisfy { $0.1.status == .reconnecting })
        #expect(await store.loadAll(userID: "user-a", teamID: "team-b").isEmpty)
    }

    @Test
    func authoritativeEmptyListRemovesThePreviousPreview() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let workspace = MobileWorkspacePreview(
            id: "workspace-a",
            macDeviceID: "mac-a",
            name: "Mario",
            terminals: []
        )
        let connected = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [workspace],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
        let empty = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )

        await store.save(state: connected, userID: "user-a", teamID: "team-a", pairing: pairing)
        await store.save(state: empty, userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(store.load(userID: "user-a", teamID: "team-a", pairing: pairing) == nil)
        #expect(await store.loadAll(userID: "user-a", teamID: "team-a").isEmpty)
    }

    @Test
    func authoritativeEmptyGroupsRemainAuthoritativeAfterRestore() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [MobileWorkspacePreview(id: "workspace-a", macDeviceID: "mac-a", name: "Mario", terminals: [])],
            workspaceGroupsAreAuthoritative: true,
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )

        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(store.load(userID: "user-a", teamID: "team-a", pairing: pairing)?.workspaceGroupsAreAuthoritative == true)
    }

    @Test
    func malformedSnapshotsAreRemovedWhenTheStoreIsTouched() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [MobileWorkspacePreview(id: "workspace-a", macDeviceID: "mac-a", name: "Mario", terminals: [])],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let storageKey = defaults.dictionaryRepresentation().keys.first { $0.contains("cmux.mobile.v2.workspace-snapshot.") }!
        defaults.set(Data("not-json".utf8), forKey: storageKey)

        #expect(await store.loadAll(userID: "user-a", teamID: "team-a").isEmpty)
        #expect(defaults.data(forKey: storageKey) == nil)
    }

    @Test
    func expiredSnapshotsAreRemovedWhenTheStoreIsTouched() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [MobileWorkspacePreview(id: "workspace-a", macDeviceID: "mac-a", name: "Mario", terminals: [])],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let storageKey = defaults.dictionaryRepresentation().keys.first { $0.contains("cmux.mobile.v2.workspace-snapshot.") }!
        var object = try! JSONSerialization.jsonObject(with: defaults.data(forKey: storageKey)!) as! [String: Any]
        object["savedAt"] = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60).timeIntervalSinceReferenceDate
        defaults.set(try! JSONSerialization.data(withJSONObject: object), forKey: storageKey)

        #expect(await store.loadAll(userID: "user-a", teamID: "team-a").isEmpty)
        #expect(defaults.data(forKey: storageKey) == nil)
    }
}
