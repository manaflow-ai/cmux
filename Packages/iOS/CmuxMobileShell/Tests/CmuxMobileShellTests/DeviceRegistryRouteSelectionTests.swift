import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests the pure reconnect-route policy and registry-response parsing. These
/// are the heart of the auto-pair-on-reload path: the policy decides when a
/// stale-route Mac is rescued by registry routes versus when the locally
/// persisted routes win (so pairing survives the registry being down).
@Suite struct DeviceRegistryRouteSelectionTests {
    private func route(host: String, port: Int, id: String = "r", priority: Int = 0) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    @Test func registryUnavailableFallsBackToLocal() throws {
        let local = [try route(host: "100.0.0.1", port: 51000)]
        // nil == registry unreachable / unauthorized / Mac not registered.
        #expect(DeviceRegistryService.selectReconnectRoutes(local: local, registry: nil) == nil)
    }

    @Test func registryEmptyFallsBackToLocal() throws {
        let local = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryService.selectReconnectRoutes(local: local, registry: []) == nil)
    }

    @Test func identicalRegistryRoutesAreANoOp() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        #expect(DeviceRegistryService.selectReconnectRoutes(local: routes, registry: routes) == nil)
    }

    @Test func differentRegistryRoutesWin() throws {
        // The Mac moved networks / changed port: registry has the current route.
        let local = [try route(host: "100.0.0.1", port: 51000)]
        let registry = [try route(host: "100.9.9.9", port: 51999)]
        let selected = DeviceRegistryService.selectReconnectRoutes(local: local, registry: registry)
        #expect(selected == registry)
    }

    @Test func parsesRoutesForMatchingMacFromListResponse() throws {
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "AAAA1111-1111-4111-8111-111111111111",
              "platform": "mac",
              "displayName": "Other Mac",
              "instances": [{ "tag": "stable", "routes": [] }]
            },
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "displayName": "Lawrence's Mac",
              "instances": [
                { "tag": "stale", "routes": [] },
                {
                  "tag": "stable",
                  "routes": [
                    { "id": "r1", "kind": "tailscale", "priority": 0,
                      "endpoint": { "type": "host_port", "host": "100.9.9.9", "port": 51999 } }
                  ]
                }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        // Case-insensitive id match (the wire id may be upper- or lower-cased).
        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
        if case let .hostPort(host, port) = routes?.first?.endpoint {
            #expect(host == "100.9.9.9")
            #expect(port == 51999)
        } else {
            Issue.record("expected a host_port route")
        }
    }

    @Test func returnsNilWhenMacNotInListResponse() {
        let json = #"{ "teamId": "team-a", "devices": [] }"#.data(using: .utf8)!
        #expect(DeviceRegistryService.routes(forMacDeviceID: "missing", in: json) == nil)
    }

    @Test func multipleNonEmptyInstancesReturnNilToAvoidWrongTag() {
        // A Mac running two tagged builds (stable + debug), both advertising
        // routes. Without a tag to match, substituting either could connect the
        // phone to the wrong app, so fall back to local routes (nil).
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "r1", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.1.1.1", "port": 51001 } }
                ] },
                { "tag": "debug", "routes": [
                  { "id": "r2", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.2.2.2", "port": 51002 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        #expect(DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        ) == nil)
    }

    @Test func singleNonEmptyInstanceAmongEmptyOnesIsUsed() throws {
        // Multiple instances but only one advertising routes (e.g. stable on,
        // a debug build that turned pairing off): use the single non-empty one.
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "debug", "routes": [] },
                { "tag": "stable", "routes": [
                  { "id": "r1", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.1.1.1", "port": 51001 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
    }

    @Test func malformedSiblingRouteDoesNotPoisonTheList() throws {
        // One instance has a malformed/unknown route; the target Mac's own valid
        // route must still parse (a bad sibling must not nil the whole response).
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "AAAA1111-1111-4111-8111-111111111111",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "bad", "kind": "unknown_future_kind", "endpoint": { "type": "???" } }
                ] }
              ]
            },
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "r1", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.9.9.9", "port": 51999 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
    }

    @Test func malformedRouteWithinTargetInstanceIsSkipped() throws {
        // A bad route mixed with a good one in the target's own instance: keep
        // the good one, drop the bad one.
        let json = """
        {
          "teamId": "team-a",
          "devices": [
            {
              "deviceId": "BBBB2222-2222-4222-8222-222222222222",
              "platform": "mac",
              "instances": [
                { "tag": "stable", "routes": [
                  { "id": "bad", "kind": "tailscale", "endpoint": { "type": "host_port", "host": "", "port": 0 } },
                  { "id": "good", "kind": "tailscale", "priority": 0,
                    "endpoint": { "type": "host_port", "host": "100.9.9.9", "port": 51999 } }
                ] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let routes = DeviceRegistryService.routes(
            forMacDeviceID: "bbbb2222-2222-4222-8222-222222222222",
            in: json
        )
        #expect(routes?.count == 1)
        #expect(routes?.first?.id == "good")
    }

    @Test func appliesRefreshWhenStillSignedInSameUserSameActiveMac() {
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: "mac-1",
            targetMacID: "mac-1"
        ) == true)
    }

    @Test func rejectsRefreshAfterSignOut() {
        // User signed out while freshRoutes was in flight: never resurrect.
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: false,
            capturedUserID: "user-1",
            currentUserID: nil,
            activeMacID: nil,
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func rejectsRefreshAfterUserSwitch() {
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-2",
            activeMacID: "mac-1",
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func rejectsRefreshAfterMacHidden() {
        // The Mac was hidden (no active Mac now): do not recreate it.
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: nil,
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func rejectsRefreshAfterActiveMacSwitched() {
        // The user switched to a different active Mac (e.g. rescanned a QR):
        // do not reactivate the old one.
        #expect(DeviceRegistryService.shouldApplyRegistryRefresh(
            isSignedIn: true,
            capturedUserID: "user-1",
            currentUserID: "user-1",
            activeMacID: "mac-2",
            targetMacID: "mac-1"
        ) == false)
    }

    @Test func deviceIdentityPersistsAcrossLookups() {
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore()

        let first = DeviceRegistryService.deviceID(store: store, defaults: defaults)
        let second = DeviceRegistryService.deviceID(store: store, defaults: defaults)
        #expect(first == second)
        #expect(!first.isEmpty)
        // Stable across a fresh accessor reading the same store (relaunch proxy).
        #expect(UUID(uuidString: first) != nil)
        // The generated id is persisted to the authoritative (Keychain) store.
        #expect(store.read() == .found(first))
    }

    @Test func preWitnessMirrorIsNotAdoptedWithoutDeviceContinuityEvidence() {
        // Restored-backup proxy for the PRE-WITNESS population: the mirror
        // migrated over in a backup taken by a build that never recorded a
        // device witness, the ThisDeviceOnly Keychain item did not, and no
        // non-migrating artifact proves this is the same physical device.
        // Witness absence is not identity evidence — every backup taken before
        // the witness shipped looks exactly like this, so adopting here gives
        // TWO phones the old device id and one (user, device, tag) binding
        // slot to fight over. Without continuity evidence, mint fresh.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let migratedMirror = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(migratedMirror, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.deviceID(
            store: store,
            defaults: defaults,
            deviceWitness: "witness-new-phone",
            evidence: StaticEvidenceProbe(.absent)
        )

        #expect(resolved != migratedMirror)
        #expect(UUID(uuidString: resolved) != nil)
        #expect(store.read() == .found(resolved))
    }

    @Test func whitespaceOnlyPersistedIdentityIsReplacedNotAdopted() {
        // A corrupt persisted item holding only whitespace must be treated like
        // any other corrupt value: replaced by a freshly minted id. Classifying
        // it as `.found` instead deadlocks the repair — the resolver notices the
        // blank and tries to mint, but the store's duplicate-item adoption path
        // re-reads the same whitespace value and adopts it, so every launch
        // advertises an invalid opaque device id and the corrupt item is never
        // overwritten.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore(seed: "   ")

        let resolved = DeviceRegistryService.deviceID(store: store, defaults: defaults)

        // A usable minted identity, never the whitespace value.
        #expect(UUID(uuidString: resolved) != nil)
        // The corrupt item was overwritten with the minted id.
        #expect(store.read() == .found(resolved))
    }

    @Test func deviceIdentityMintsFreshWhenMirrorWitnessBelongsToAnotherPhone() {
        // Phone-restore proxy: `UserDefaults` migrated over in the backup —
        // including the mirror AND the old phone's device witness — but the
        // ThisDeviceOnly Keychain item did not, so the Keychain authoritatively
        // reports the id ABSENT and this phone's witness differs. Adopting the
        // mirror would give TWO physical devices the same device id, and their
        // registrations would fight over one (user, device, tag) binding slot
        // on every reconnect. A fresh id must be minted and persisted, and the
        // mirror re-pointed at it under THIS device's witness.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let migratedMirror = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(migratedMirror, forKey: "cmux.deviceRegistry.iosDeviceID")
        defaults.set("witness-old-phone", forKey: DeviceRegistryService.deviceWitnessKey)
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.deviceID(
            store: store,
            defaults: defaults,
            deviceWitness: "witness-new-phone"
        )
        // A fresh identity, never the mirror that belongs to another phone.
        #expect(resolved != migratedMirror)
        #expect(UUID(uuidString: resolved) != nil)
        // Persisted authoritatively; mirror and witness now track this device.
        #expect(store.read() == .found(resolved))
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == resolved)
        #expect(
            defaults.string(forKey: DeviceRegistryService.deviceWitnessKey) == "witness-new-phone"
        )
    }

    @Test func deviceIdentityAdoptsPreWitnessMirrorOnInPlaceUpgrade() {
        // The in-place upgrade population: a pre-Keychain install whose mirror
        // holds the id its LIVE binding already uses, with no witness recorded
        // (older builds never wrote one). Witness absence alone proves nothing
        // (a restored pre-witness backup looks identical), so adoption is
        // gated on same-device evidence: a non-migrating artifact — the
        // ThisDeviceOnly legacy identity item an established install
        // necessarily wrote — proves the install is continuing on this
        // hardware. With that evidence the pre-Keychain id is preserved, and
        // this device's witness is recorded so a future restore of this
        // backup onto another phone IS detectable.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(legacy, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.deviceID(
            store: store,
            defaults: defaults,
            deviceWitness: "witness-this-phone",
            evidence: StaticEvidenceProbe(.present)
        )
        // The pre-Keychain id is preserved, so the binding slot survives.
        #expect(resolved == legacy)
        // Promoted into the authoritative store, with the witness recorded.
        #expect(store.read() == .found(legacy))
        #expect(
            defaults.string(forKey: DeviceRegistryService.deviceWitnessKey) == "witness-this-phone"
        )
    }

    @Test func deviceIdentityMintsForPreWitnessMirrorWithoutSameDeviceEvidence() {
        // Same pre-witness mirror, but NO same-device evidence: this is
        // indistinguishable from a restored backup on a new phone, so mint
        // fresh instead of cloning the old phone's `(user, device, tag)`
        // identity.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(legacy, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.deviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.absent)
        )
        #expect(resolved != legacy)
        #expect(UUID(uuidString: resolved) != nil)
        #expect(store.read() == .found(resolved))
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == resolved)
    }

    @Test func deviceIdentityAdoptsMirrorWhoseWitnessMatchesThisPhone() {
        // Same-device Keychain loss (the item vanished but defaults survived):
        // the recorded witness matches this device, so the mirror provably
        // belongs here and is adopted rather than replaced — no evidence probe
        // is consulted (an unavailable probe must not block the proven case).
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirrored = "mirrored-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(mirrored, forKey: "cmux.deviceRegistry.iosDeviceID")
        defaults.set("witness-this-phone", forKey: DeviceRegistryService.deviceWitnessKey)
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.deviceID(
            store: store,
            defaults: defaults,
            deviceWitness: "witness-this-phone",
            evidence: StaticEvidenceProbe(.unavailable)
        )
        #expect(resolved == mirrored)
        #expect(store.read() == .found(mirrored))
    }

    @Test func deviceIdentityWitnessMismatchOverridesStaleEvidence() {
        // Backup restored onto a phone whose PREVIOUS cmux install left a stale
        // ThisDeviceOnly endpoint-identity item behind (Keychain items outlive
        // app deletion): the probe reports `.present`, but the mirror's
        // recorded witness belongs to the OTHER phone. The witness verdict must
        // win — adopting here would give two phones one binding slot.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let foreign = "restored-foreign-id-\(UUID().uuidString.lowercased())"
        defaults.set(foreign, forKey: "cmux.deviceRegistry.iosDeviceID")
        defaults.set("witness-old-phone", forKey: DeviceRegistryService.deviceWitnessKey)
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.deviceID(
            store: store,
            defaults: defaults,
            deviceWitness: "witness-new-phone",
            evidence: StaticEvidenceProbe(.present)
        )
        #expect(resolved != foreign)
        #expect(UUID(uuidString: resolved) != nil)
        #expect(store.read() == .found(resolved))
    }

    @Test func deviceIdentitySurvivesUserDefaultsWipe() {
        // Reinstall proxy: Keychain retains the id, UserDefaults is empty.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = "kept-device-id-\(UUID().uuidString.lowercased())"
        let store = InMemoryDeviceIdentityStore(seed: kept)

        let resolved = DeviceRegistryService.deviceID(store: store, defaults: defaults)
        #expect(resolved == kept)
        // The authoritative read path re-mirrors the id into UserDefaults so a
        // later downgrade to a UserDefaults-only build keeps the same slot.
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == kept)
    }

    @Test func deviceIdentityFailsClosedWhenStoreUnavailableWithLegacyMirror() {
        // Locked-Keychain proxy on a CONTINUING install: the store cannot be
        // read, a pre-witness UserDefaults mirror exists, and device-continuity
        // evidence proves the install is still on this hardware. Reuse the
        // mirror instead of minting a new id that would strand the existing
        // binding. (Without the evidence this defers instead — a restored
        // backup's mirror must not be trusted just because the Keychain is
        // locked.)
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirrored = "mirrored-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(mirrored, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore(unavailable: true)

        let resolved = DeviceRegistryService.deviceID(
            store: store,
            defaults: defaults,
            evidence: StaticEvidenceProbe(.present)
        )
        #expect(resolved == mirrored)
        // The unreadable store must not have been overwritten with a new id.
        #expect(store.read() == .unavailable)
    }

    @Test func deviceIdentityFailsClosedWithEphemeralWhenStoreUnavailableAndNoMirror() {
        // Worst case: store unreadable AND no UserDefaults mirror (background
        // launch before first unlock on a fresh install). Return a process-stable
        // id WITHOUT persisting it, so the next unlocked launch mints the durable
        // id rather than freezing this throwaway value.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore(unavailable: true)

        let first = DeviceRegistryService.deviceID(store: store, defaults: defaults)
        let second = DeviceRegistryService.deviceID(store: store, defaults: defaults)
        #expect(!first.isEmpty)
        // Stable within the process so repeated lookups agree.
        #expect(first == second)
        // Nothing was persisted: neither the store nor the mirror was written.
        #expect(store.read() == .unavailable)
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == nil)
    }

    @Test func durableDeviceIDDefersWhenMintCannotPersist() {
        // The Keychain is READABLE (it reports the id absent) but WRITES fail.
        // Nothing durable can hold a freshly minted id in that state — only the
        // reinstall-volatile UserDefaults mirror would — so advertising one
        // registers a binding a delete-and-reinstall strands: the wipe loses
        // the id and the next launch mints a different one. The binding path
        // must defer and retry until the Keychain confirms persistence,
        // regardless of any mirror value sitting in UserDefaults.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "legacy-device-id-\(UUID().uuidString.lowercased())",
            forKey: "cmux.deviceRegistry.iosDeviceID"
        )
        let store = InMemoryDeviceIdentityStore(writeAlwaysFails: true)

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.absent)
        )

        #expect(resolved == nil)
    }

    @Test func deviceIdentityKeychainWinsOverUserDefaults() {
        // If both stores hold a value, the Keychain (authoritative) one wins.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("stale-userdefaults-id", forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore(seed: "authoritative-keychain-id")

        let resolved = DeviceRegistryService.deviceID(store: store, defaults: defaults)
        #expect(resolved == "authoritative-keychain-id")
    }

    // MARK: - Durable device id (binding-registration path)

    @Test func simulatorSeedIsAnAuthoritativeDurableDeviceID() {
        // Unsigned simulator apps cannot use the data-protection Keychain. The
        // launcher writes this deterministic seed before launch, so the
        // simulator-specific authoritative store must return it directly
        // instead of treating it as a backup-restorable migration mirror.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let seeded = "simulator-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(seeded, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = SimulatorDeviceIdentityStore(defaults: defaults)

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store,
            defaults: defaults,
            evidence: StaticEvidenceProbe(.absent)
        )

        #expect(resolved == seeded)
        #expect(store.read() == .found(seeded))
    }

    @Test func simulatorSeedIsAdoptedIntoTheDurableDefaultsStore() {
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let seeded = "simulator-device-id-\(UUID().uuidString.lowercased())"
        let firstLaunch = SimulatorDeviceIdentityStore(
            defaults: defaults,
            seededDeviceID: seeded
        )

        #expect(firstLaunch.read() == .found(seeded))

        let springboardRelaunch = SimulatorDeviceIdentityStore(defaults: defaults)
        #expect(springboardRelaunch.read() == .found(seeded))
    }

    @Test func blankSimulatorSeedMintsOnceAndSurvivesRelaunch() {
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstLaunch = SimulatorDeviceIdentityStore(
            defaults: defaults,
            seededDeviceID: " \n "
        )

        let resolved = DeviceRegistryService.durableDeviceID(
            store: firstLaunch,
            defaults: defaults,
            evidence: StaticEvidenceProbe(.absent)
        )
        let springboardRelaunch = SimulatorDeviceIdentityStore(defaults: defaults)

        #expect(resolved != nil)
        if let resolved {
            #expect(springboardRelaunch.read() == .found(resolved))
        }
    }

    @Test func durableDeviceIDMintsAndPersistsOnFreshInstall() {
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.durableDeviceID(store: store, defaults: defaults)
        // A fresh mint is durable only because the store confirmed the write.
        #expect(resolved != nil)
        if let resolved {
            #expect(store.read() == .found(resolved))
        }
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == resolved)
    }

    @Test func durableDeviceIDReturnsMirrorWhenStoreUnavailable() {
        // Locked-Keychain proxy with a legacy pre-witness mirror on a proven
        // CONTINUING install: the established id is still durable (it is the id
        // the existing binding uses), so return it.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirrored = "mirrored-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(mirrored, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore(unavailable: true)

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store,
            defaults: defaults,
            evidence: StaticEvidenceProbe(.present)
        )
        #expect(resolved == mirrored)
    }

    @Test func durableDeviceIDDefersForPreWitnessMirrorWithoutContinuityEvidence() {
        // Locked Keychain + pre-witness mirror + NO same-device evidence: this
        // is indistinguishable from a restored backup's first background launch
        // on a NEW phone. Returning the mirror as durable would register the
        // old phone's id from the new phone; minting would strand a continuing
        // install's binding. Defer instead — the next unlocked launch resolves
        // through the authoritative path.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirrored = "mirrored-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(mirrored, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore(unavailable: true)

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.absent)
        )
        #expect(resolved == nil)
    }

    @Test func durableDeviceIDDefersWhenStoreUnavailableAndNoMirror() {
        // The finding-1 core case: unreadable Keychain, no mirror. Return nil so
        // the caller defers registering a binding instead of minting a throwaway
        // id that would strand the retained (user, device, tag) slot.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore(unavailable: true)

        let resolved = DeviceRegistryService.durableDeviceID(store: store, defaults: defaults)
        #expect(resolved == nil)
        // Nothing minted or mirrored: a later unlocked launch resolves the durable id.
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == nil)
    }

    @Test func durableDeviceIDDefersWhenFreshMintCannotPersist() {
        // The finding-3 core case: the store is readable-but-empty yet rejects the
        // write. Do not advertise the un-persisted mint as durable, and do not
        // mirror it (only reinstall-volatile UserDefaults would hold it, so a
        // reinstall would mint a different id and strand the binding).
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore(writeAlwaysFails: true)

        let resolved = DeviceRegistryService.durableDeviceID(store: store, defaults: defaults)
        #expect(resolved == nil)
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == nil)
    }

    @Test func durableDeviceIDRejectsRestoredLegacyWhenFreshMintCannotPersist() {
        // A UserDefaults-only id with NO same-device evidence is not durable
        // for this physical device: it may have arrived in a restored backup.
        // If the empty authoritative store also cannot persist a fresh id,
        // defer registration and remove the unsafe mirror instead of cloning
        // another phone's identity.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(legacy, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore(writeAlwaysFails: true)

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.absent),
        )
        #expect(resolved == nil)
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == nil)
    }

    // MARK: - Upgrade vs restore disambiguation (9071 review finding 1)

    @Test func durableDeviceIDAdoptsLegacyMirrorOnInPlaceUpgrade() {
        // In-place upgrade from a pre-Keychain build: device-id Keychain item is
        // absent, the legacy mirror holds this phone's established id, and the
        // ThisDeviceOnly legacy identity Keychain item proves same-device
        // continuation. The resolver must ADOPT the mirror — minting would
        // target a new (user, device, tag) identity while account services
        // still track the old one.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(legacy, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.present),
        )
        #expect(resolved == legacy)
        // Adopted into the authoritative store and still mirrored.
        #expect(store.read() == .found(legacy))
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == legacy)
    }

    @Test func durableDeviceIDMintsFreshOnCrossDeviceRestore() {
        // Backup restore onto different hardware: the mirror crossed devices
        // inside the backup, but the ThisDeviceOnly endpoint identity did not.
        // Adopting the mirror would make two phones share one slot; mint fresh.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let foreign = "restored-foreign-id-\(UUID().uuidString.lowercased())"
        defaults.set(foreign, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.absent),
        )
        #expect(resolved != nil)
        #expect(resolved != foreign)
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == resolved)
    }

    @Test func durableDeviceIDDefersWhenEvidenceUnreadableWithLegacyMirror() {
        // Locked Keychain during the evidence probe: cannot distinguish upgrade
        // from restore. Minting would rotate an upgrading device's identity, so
        // fail closed and let the caller retry after first unlock.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = "legacy-device-id-\(UUID().uuidString.lowercased())"
        defaults.set(legacy, forKey: "cmux.deviceRegistry.iosDeviceID")
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.unavailable),
        )
        #expect(resolved == nil)
        // Nothing minted, mirror preserved for the post-unlock retry.
        #expect(store.read() == .absent)
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == legacy)
    }

    @Test func durableDeviceIDMintsOnFreshInstallRegardlessOfEvidence() {
        // No mirror at all: evidence is irrelevant; a fresh install mints even
        // if a stale endpoint-identity item lingers from a previous install.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryDeviceIdentityStore()

        let resolved = DeviceRegistryService.durableDeviceID(
            store: store, defaults: defaults, evidence: StaticEvidenceProbe(.present),
        )
        #expect(resolved != nil)
        if let resolved {
            #expect(store.read() == .found(resolved))
        }
    }

    @Test func durableDeviceIDAdoptsConcurrentWinnerInsteadOfMintingSecondID() {
        // Two launches both read an empty Keychain and each mint a different
        // candidate. The one that loses the store's create race must adopt the
        // winner's id so both converge on ONE (user, device, tag) slot. The prior
        // last-writer-wins persistence let the loser overwrite the winner, so the
        // winner's caller advertised an id the store no longer held and stranded
        // that binding on the next launch. Here the store reports empty on read
        // (mint path) but returns a concurrent winner from createOrAdopt; the
        // resolver must return the winner, not its own freshly minted candidate.
        let suite = "test.deviceRegistry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let winner = "winner-device-id-\(UUID().uuidString.lowercased())"
        let store = ConcurrentCreateWinnerStore(winner: winner)

        let resolved = DeviceRegistryService.durableDeviceID(store: store, defaults: defaults)
        #expect(resolved == winner)
        // The adopted winner is mirrored so a later UserDefaults-only build agrees.
        #expect(defaults.string(forKey: "cmux.deviceRegistry.iosDeviceID") == winner)
    }

    @Test func inMemoryCreateOrAdoptAdoptsExistingValueInsteadOfOverwriting() {
        // The InMemory double must model the Keychain SecItemAdd-first contract:
        // createOrAdopt never clobbers a value already present, it adopts it. This
        // is the store-level guarantee the convergence above relies on.
        let store = InMemoryDeviceIdentityStore(seed: "existing-winner")
        let adopted = store.createOrAdopt("late-candidate")
        #expect(adopted == "existing-winner")
        #expect(store.read() == .found("existing-winner"))
    }
}

/// A store that reports empty on `read()` (so the resolver takes the mint path)
/// yet returns a winner a concurrent resolution already persisted from
/// `createOrAdopt`, modelling the Keychain `errSecDuplicateItem` race where two
/// launches both saw an empty store before either wrote.
private final class ConcurrentCreateWinnerStore: DeviceIdentityStoring, @unchecked Sendable {
    private let winner: String
    init(winner: String) { self.winner = winner }
    func read() -> DeviceIdentityReadResult { .absent }
    func createOrAdopt(_ desired: String) -> String? { winner }
}
