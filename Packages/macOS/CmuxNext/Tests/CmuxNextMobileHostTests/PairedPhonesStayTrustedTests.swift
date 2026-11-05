import CmuxNextMobile
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A phone the person allowed once stays allowed until they remove it (2026-11-04: "why am I having to
/// approve on my Mac for phone use too often"). On the user's Mac the Keychain refused the app's own
/// pairing seal for two launches after a nightly update (`errSecMissingEntitlement`, then the login
/// Keychain's `errSecAuthFailed`), each read as "the list was tampered with", so every phone had to be
/// allowed again; and any session that ended by itself ran the sign-out path that forgets every phone.
@Suite(.timeLimit(.minutes(1))) struct PairedPhonesStayTrustedTests {
    static let phone = MobileHostPairRequest(phoneDeviceID: "phone-a", name: "iPhone",
                                             identityKey: "04" + String(repeating: "aa", count: 64),
                                             approvalKey: "04" + String(repeating: "bb", count: 64))
    static let newPhone = MobileHostPairRequest(phoneDeviceID: "phone-b", name: "iPad",
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
        #expect(!store.trusts(Self.phone))
        store.select(userID: nil)
        store.select(userID: "u")
        await store.reload()
        #expect(!store.trusts(Self.phone))
        let relaunched = await Self.launch(directory, seal: seal)
        #expect(!relaunched.trusts(Self.phone))
    }
}
