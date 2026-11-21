@testable import CmuxNextMobile
import CmuxNextWakeupsTestSupport
import Foundation
import Security
import Testing

/// A phone the person allowed once stays allowed until they remove it (2026-11-04: "why am I having to
/// approve on my Mac for phone use too often"). On the user's Mac the Keychain refused the app's own
/// pairing seal for two launches after a nightly update (`errSecMissingEntitlement`, then the login
/// Keychain's `errSecAuthFailed`), each read as "the list was tampered with", so every phone had to be
/// allowed again; and any session that ended by itself ran the sign-out path that forgets every phone.
@Suite(.timeLimit(.minutes(1))) struct PairedPhonesStayTrustedTests {
    nonisolated static let phone = MobileHostPairRequest(phoneDeviceID: "phone-a", name: "iPhone",
                                             identityKey: "04" + String(repeating: "aa", count: 64),
                                             approvalKey: "04" + String(repeating: "bb", count: 64))
    nonisolated static let newPhone = MobileHostPairRequest(phoneDeviceID: "phone-b", name: "iPad",
                                                identityKey: "04" + String(repeating: "cc", count: 64),
                                                approvalKey: "04" + String(repeating: "dd", count: 64))

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A launch of the app for user "u" on `directory`, its list read.
    static func launch(_ directory: URL, seal: MobileHostMemoryPairingSeal, clock: ManualClock = ManualClock()) async -> MobileHostPairedStore {
        let store = MobileHostPairedStore(seal: seal, clock: clock)
        store.select(userID: "u")
        await store.attach(directory: directory)
        return store
    }

    /// The person allowed `phone` in an earlier run.
    static func allowed(_ directory: URL, seal: MobileHostMemoryPairingSeal) async throws {
        let store = await launch(directory, seal: seal)
        try await store.change(for: "u") { $0.approve(Self.phone, at: Date(timeIntervalSince1970: 5)) }
        #expect(store.trusts(Self.phone))
    }

    /// Yields until `condition` holds (bounded by the suite's limit).
    static func until(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    /// The user's own launches of 2026-11-03, replayed: allowed once, then a nightly launch whose
    /// Keychain refuses the seal through every wait (the person allows the phone again), a second launch
    /// whose Keychain refuses at first and then answers, a session that ends by itself, and a healthy
    /// launch. Only the first refused launch may ask; every later launch trusts the phone with no Allow.
    @Test func thePhoneAllowedOnceIsNotAskedAboutAgainAcrossSeveralLaunches() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)

        // 23:18 UTC: the Keychain refuses through every wait; the person allows the phone again.
        seal.refuseAll()
        let firstClock = ManualClock()
        let first = await Self.launch(directory, seal: seal, clock: firstClock)
        for wait in MobileHostPairedStore.sealWaits {
            try await firstClock.waitForSleeper()
            firstClock.advance(by: wait)
        }
        await Self.until { first.current != nil }
        #expect(!first.trusts(Self.phone))
        try await first.change(for: "u") { $0.approve(Self.phone, at: Date(timeIntervalSince1970: 7)) }
        #expect(first.trusts(Self.phone))

        // 23:26 UTC: refused at launch, answers during the first wait.
        let secondClock = ManualClock()
        let second = await Self.launch(directory, seal: seal, clock: secondClock)
        #expect(!second.trusts(Self.phone))
        seal.answerAgain()
        try await secondClock.waitForSleeper()
        secondClock.advance(by: .seconds(1))
        await Self.until { second.current != nil }
        #expect(second.trusts(Self.phone), "the second launch asked about the phone again")

        // The session ends by itself, then the same account signs in again.
        second.select(userID: nil)
        second.select(userID: "u")
        await second.reload()
        #expect(second.trusts(Self.phone), "a session that ended by itself asked about the phone again")

        // A healthy launch later still trusts the phone from the sealed list.
        let third = await Self.launch(directory, seal: seal)
        #expect(third.trusts(Self.phone), "a healthy launch after the refusals asked about the phone again")
        #expect(third.current?.devices.count == 1)
    }

    /// The Keychain refuses the seal at launch, then answers: the phone is trusted again with no
    /// Allow, and while it refused no phone was trusted and none asked about (no list yet).
    @Test func aSealRefusedAtLaunchTrustsThePhoneOnceTheKeychainAnswers() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)

        seal.refuseAll()
        let clock = ManualClock()
        let store = await Self.launch(directory, seal: seal, clock: clock)
        #expect(store.current == nil, "a refused seal read as an empty list: every phone is asked about again")
        #expect(!store.trusts(Self.phone))

        seal.answerAgain()
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(1))
        await Self.until { store.current != nil }
        #expect(store.trusts(Self.phone), "the phone allowed before the update must not be asked about again")
    }

    /// The Keychain keeps refusing past the waits: the phones are asked about, but those answers stay in
    /// memory, so the next launch whose Keychain answers still trusts the phone allowed before.
    @Test func answersWhileTheSealIsRefusedLeaveTheStoredListForTheNextLaunch() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)

        seal.refuseAll()
        let clock = ManualClock()
        let refused = await Self.launch(directory, seal: seal, clock: clock)
        for wait in MobileHostPairedStore.sealWaits {
            try await clock.waitForSleeper()
            clock.advance(by: wait)
        }
        await Self.until { refused.current != nil }
        #expect(refused.current?.devices.isEmpty == true)
        try await refused.change(for: "u") { $0.approve(Self.newPhone, at: Date(timeIntervalSince1970: 6)) }
        #expect(refused.trusts(Self.newPhone), "an Allow while the Keychain refuses still admits the phone in this run")

        seal.answerAgain()
        let next = await Self.launch(directory, seal: seal)
        #expect(next.trusts(Self.phone), "the run whose Keychain refused rewrote the stored list: the phone is asked about again")
    }

    /// A session that ends by itself (no sign-out by the person) keeps the phones: the same account
    /// signing in again is trusted by them with no Allow, in this run and after a relaunch.
    @Test func aSessionThatEndsByItselfKeepsThePairedPhones() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let store = await Self.launch(directory, seal: seal)
        try await store.change(for: "u") { $0.approve(Self.phone, at: Date(timeIntervalSince1970: 5)) }

        store.select(userID: nil)
        #expect(!store.trusts(Self.phone), "signed out, no phone is trusted")
        store.select(userID: "u")
        await store.reload()
        #expect(store.trusts(Self.phone), "an expired session forgot the paired phone")
        let relaunched = await Self.launch(directory, seal: seal)
        #expect(relaunched.trusts(Self.phone))
    }

    /// The person's own sign-out still forgets the phones, in this run and after a relaunch.
    @Test func thePersonsSignOutForgetsThePairedPhones() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let store = await Self.launch(directory, seal: seal)
        try await store.change(for: "u") { $0.approve(Self.phone, at: Date(timeIntervalSince1970: 5)) }

        store.forgetForSignOut()
        #expect(store.current == nil && !store.trusts(Self.phone), "nothing is trusted or asked about while the sign-out runs")
        store.select(userID: nil)
        store.select(userID: "u")
        await store.reload()
        #expect(!store.trusts(Self.phone))
        let relaunched = await Self.launch(directory, seal: seal)
        #expect(!relaunched.trusts(Self.phone))
    }

    /// Past the waits, with the Keychain still refusing (the memory-only run).
    static func refusedPastTheWaits(_ directory: URL, seal: MobileHostMemoryPairingSeal) async throws -> MobileHostPairedStore {
        seal.refuseAll()
        let clock = ManualClock()
        let store = await launch(directory, seal: seal, clock: clock)
        for wait in MobileHostPairedStore.sealWaits {
            try await clock.waitForSleeper()
            clock.advance(by: wait)
        }
        await until { store.current != nil }
        return store
    }

    /// Review of #36157, finding 2: a Don't Allow given while the seal is refused is written (fail
    /// closed), so the next launch does not trust the refused phone from the stored list.
    @Test func aDenyWhileTheSealIsRefusedIsNotUndoneAtTheNextLaunch() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)
        let refused = try await Self.refusedPastTheWaits(directory, seal: seal)
        try await refused.change(for: "u") { $0.deny(Self.phone) }
        seal.answerAgain()
        let next = await Self.launch(directory, seal: seal)
        #expect(!next.trusts(Self.phone), "a phone refused while the Keychain refused was trusted again")
    }

    /// Review of #36157, finding 4: a second read while a refused seal's wait is pending starts no
    /// second chain of waits.
    @Test func aSecondReadDuringTheWaitStartsNoSecondChain() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)
        seal.refuseAll()
        let clock = ManualClock()
        let store = await Self.launch(directory, seal: seal, clock: clock)
        try await clock.waitForSleeper()
        await store.reload()
        await store.reload()
        #expect(clock.sleeperCount == 1)
    }

    /// Review of #36157, finding 7: an Allow given while the seal was refused joins the stored list once
    /// the Keychain answers, and both phones stay trusted after a relaunch.
    @Test func anAllowWhileTheSealIsRefusedJoinsTheListOnceTheKeychainAnswers() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)
        let refused = try await Self.refusedPastTheWaits(directory, seal: seal)
        try await refused.change(for: "u") { $0.approve(Self.newPhone, at: Date(timeIntervalSince1970: 6)) }
        seal.answerAgain()
        await refused.reload()
        #expect(refused.trusts(Self.phone) && refused.trusts(Self.newPhone))
        let next = await Self.launch(directory, seal: seal)
        #expect(next.trusts(Self.phone) && next.trusts(Self.newPhone))
    }

    /// Review of #36157 after the merge with multi-machine pairing: a Mac allowed while the seal is refused
    /// joins the stored list as a Mac, so the next launch trusts it and does not ask again.
    @Test func aMacAllowedWhileTheSealIsRefusedStaysAMac() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        try await Self.allowed(directory, seal: seal)
        let mac = MobileHostPairRequest(phoneDeviceID: "mac-b", name: "Mac", identityKey: "04" + String(repeating: "ee", count: 64),
                                        approvalKey: "04" + String(repeating: "ff", count: 64), kind: "mac")
        let refused = try await Self.refusedPastTheWaits(directory, seal: seal)
        try await refused.change(for: "u") { $0.approve(mac, at: Date(timeIntervalSince1970: 8)) }
        seal.answerAgain()
        await refused.reload()
        let next = await Self.launch(directory, seal: seal)
        #expect(next.trusts(mac), "a Mac allowed while the Keychain refused was stored as a phone and is asked about again")
        #expect(next.current?.devices.first { $0.id == "mac-b" }?.kind == "mac")
    }

    /// A change of a machine's grants while the seal is refused is written, never kept in memory only.
    @Test func aGrantsChangeWhileTheSealIsRefusedIsWritten() {
        var stored = MobileHostPairedDevices(userID: "u")
        let mac = MobileHostPairRequest(phoneDeviceID: "mac-b", name: "Mac", identityKey: "04" + String(repeating: "ee", count: 64),
                                        approvalKey: "04" + String(repeating: "ff", count: 64), kind: "mac")
        stored.approve(mac, at: Date(timeIntervalSince1970: 8))
        stored.setGrants(["view", "control"], for: "mac-b")
        var narrowed = stored
        narrowed.setGrants(["view"], for: "mac-b")
        #expect(!MobileHostPairedStore.onlyAllows(from: stored, to: narrowed, stored: stored))
    }

    /// Review of #36157: an Allow, while the seal is refused, of a phone the stored list refuses is
    /// written (fail closed), so the next launch asks about it instead of refusing it silently.
    @Test func anAllowOfAStoredRefusalWhileTheSealIsRefusedIsWritten() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let first = await Self.launch(directory, seal: seal)
        try await first.change(for: "u") { $0.deny(Self.newPhone) }
        let refused = try await Self.refusedPastTheWaits(directory, seal: seal)
        try await refused.change(for: "u") { $0.approve(Self.newPhone, at: Date(timeIntervalSince1970: 7)) }
        seal.answerAgain()
        let next = await Self.launch(directory, seal: seal)
        #expect(next.current?.decision(for: Self.newPhone) != .denied, "the phone allowed while the Keychain refused is refused silently")
    }

    /// Review of #36157: nothing read or removed while the person's sign-out runs brings the list back.
    @Test func noListComesBackWhileTheSignOutRuns() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seal = MobileHostMemoryPairingSeal()
        let store = await Self.launch(directory, seal: seal)
        try await store.change(for: "u") { $0.approve(Self.phone, at: Date(timeIntervalSince1970: 5)) }
        store.forgetForSignOut()
        store.forget(id: Self.newPhone.phoneDeviceID)
        await store.reload()
        #expect(store.current == nil)
        await #expect(throws: (any Error).self) {
            try await store.change(for: "u") { $0.approve(Self.newPhone, at: Date()) }
        }
    }

    /// Two dev builds on one Cloud backend keep their state under one storage namespace folder
    /// (`<bundle>/<namespace>/cmux-mobile-host`). Their lists were sealed under the folder above the
    /// state folder, the namespace, so both builds shared one login-Keychain item: the build that made it
    /// owned it, the other's saves got `errSecInvalidOwnerEdit` (-25244), and its paired phones were gone
    /// after a relaunch (2026-11-18, review.sh on a real iPhone: the tagged Mac listed no phone after it
    /// restarted). Each build's list is sealed under its own bundle id; a build with no namespace keeps the
    /// name it always had.
    @Test func twoBuildsOnOneBackendSealTheirListsApart() throws {
        nonisolated final class Names: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func add(_ name: String) { lock.withLock { all.append(name) } }
        }
        let namespace = "68747470733a2f2f6578616d706c65-0"
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let names = Names()
        for bundle in ["com.cmuxterm.app.debug.one", "com.cmuxterm.app.debug.two"] {
            let store = MobileHostPairedStore(named: { names.add($0); return MobileHostMemoryPairingSeal() })
            let directory = root.appending(path: "\(bundle)/\(namespace)/cmux-mobile-host")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store.configure(directory: directory,
                            sealName: MobileHostPairedStore.sealName(bundleID: bundle, storageNamespace: namespace))
        }
        #expect(names.all == ["com.cmuxterm.app.debug.one.\(namespace)", "com.cmuxterm.app.debug.two.\(namespace)"])
        // A build with no namespace (NIGHTLY, release) keeps its bundle id, so its stored list still counts.
        #expect(MobileHostPairedStore.sealName(bundleID: "com.cmuxterm.app.nightly", storageNamespace: nil) == "com.cmuxterm.app.nightly")
        #expect(MobileHostPairedStore.sealName(bundleID: "com.cmuxterm.app.nightly", storageNamespace: "") == "com.cmuxterm.app.nightly")
    }

    /// Each fleet build of a tag is signed ad hoc with its own code hash, and a login item trusts only the
    /// code that made it: a new build of the tag may never read the previous build's seal (-25293), ran
    /// with its list in memory only, wrote no seal, and lost its phones at every relaunch (2026-11-18,
    /// review.sh on a real iPhone). An ad hoc build seals under its own code; a team-signed build
    /// (NIGHTLY, release, signing info with a team) keeps the name it always had.
    @Test func anAdHocBuildSealsUnderItsOwnCode() {
        let cdhash = Data([0xab, 0xcd, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let adHoc = MobileHostPairedStore.adHocCodeIdentity(signing: [kSecCodeInfoUnique as String: cdhash])
        #expect(adHoc == "abcd010203040506")
        #expect(MobileHostPairedStore.adHocCodeIdentity(signing: [kSecCodeInfoUnique as String: cdhash,
                                                                  kSecCodeInfoTeamIdentifier as String: "7WLXT3NR37"]) == nil)
        #expect(MobileHostPairedStore.adHocCodeIdentity(signing: [:]) == nil)
        let namespace = "68747470733a2f2f6578616d706c65-0"
        let one = MobileHostPairedStore.sealName(bundleID: "com.cmuxterm.app.debug.tag", storageNamespace: namespace, adHocCode: adHoc)
        let next = MobileHostPairedStore.sealName(bundleID: "com.cmuxterm.app.debug.tag", storageNamespace: namespace, adHocCode: "1111111111111111")
        #expect(one == "com.cmuxterm.app.debug.tag.\(namespace).adhoc-abcd010203040506")
        #expect(one != next, "the next build of the tag must not reuse a seal it may not read")
        #expect(MobileHostPairedStore.sealName(bundleID: "com.cmuxterm.app.nightly", storageNamespace: nil, adHocCode: nil)
            == "com.cmuxterm.app.nightly")
    }
}
