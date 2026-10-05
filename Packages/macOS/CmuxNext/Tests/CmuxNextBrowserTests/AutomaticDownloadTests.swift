import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chrome's "automatic downloads" rule, per site, for both engines: the
/// first download a page starts without a fresh user gesture goes ahead;
/// the second asks once per site (Allow / Block); the answer is remembered
/// per profile (in memory only for a private profile); Block refuses later
/// automatic downloads without a prompt; a fresh gesture resets the count.
@MainActor
@Suite struct AutomaticDownloadTests {
    private let site = "https://files.example"
    private let other = "https://other.example"

    /// The prompt: records each question and answers with `answer`.
    final class Asker {
        var asked: [String] = []
        var answer: BrowserPromptResponse = .allow

        /// False: the question cannot show (no window, tab closed).
        var canShow = true

        func ask(_ site: String, _ reply: @escaping (BrowserPromptResponse) -> Void) -> Bool {
            asked.append(site)
            guard canShow else { return false }
            reply(answer)
            return true
        }
    }

    private func gate(_ store: SitePermissionStore, _ asker: Asker) -> AutomaticDownloadGate {
        AutomaticDownloadGate(permissions: { store }, ask: { asker.ask($0, $1) })
    }

    private func loadedStore(_ persistence: any SitePermissionPersistence = MemorySitePermissionPersistence()) async -> SitePermissionStore {
        let store = SitePermissionStore(profile: .default, persistence: persistence)
        await store.whenLoaded()
        return store
    }

    private func request(_ gate: AutomaticDownloadGate, _ site: String?) async -> Bool {
        await outcome(gate, site) == .allowed
    }

    private func outcome(_ gate: AutomaticDownloadGate, _ site: String?) async -> AutomaticDownloadGate.Outcome {
        await withCheckedContinuation { continuation in
            gate.request(site: site) { continuation.resume(returning: $0) }
        }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "nx-autodl-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "profile.json", directoryHint: .notDirectory)
    }

    @Test func policyCountsDownloadsSinceTheLastGesturePerSite() {
        var policy = AutomaticDownloadPolicy()
        let first = policy.countDownload(site: site)
        let second = policy.countDownload(site: site)
        #expect(first)
        #expect(!second)
        #expect(policy.downloadsSinceGesture == 2)
        let otherSite = policy.countDownload(site: other)
        #expect(otherSite)
        policy.userGesture()
        #expect(policy.site == nil)
        let afterGesture = policy.countDownload(site: other)
        #expect(afterGesture)
        #expect(AutomaticDownloadPolicy.decision(isFirst: true, setting: .block) == .allow)
        #expect(AutomaticDownloadPolicy.decision(isFirst: false, setting: .ask) == .ask)
        #expect(AutomaticDownloadPolicy.decision(isFirst: false, setting: .allow) == .allow)
        #expect(AutomaticDownloadPolicy.decision(isFirst: false, setting: .block) == .refuse)
    }

    @Test func theFirstGesturelessDownloadIsAllowedWithoutAsking() async {
        let asker = Asker()
        let gate = gate(await loadedStore(), asker)
        #expect(await request(gate, site))
        #expect(asker.asked.isEmpty)
    }

    @Test func theSecondDownloadAsks() async {
        let asker = Asker()
        let gate = gate(await loadedStore(), asker)
        #expect(await request(gate, site))
        #expect(await request(gate, site))
        #expect(asker.asked == [site])
    }

    /// Allow is stored for the site: later automatic downloads go ahead
    /// without a question, also after a relaunch (a new store reading the
    /// same file) and in a new tab.
    @Test func allowIsRemembered() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = await loadedStore(FileSitePermissionPersistence(fileURL: file))
        let asker = Asker()
        asker.answer = .allow
        let tab = gate(store, asker)
        #expect(await request(tab, site))
        #expect(await request(tab, site))
        #expect(await request(tab, site))
        #expect(asker.asked == [site])
        #expect(store.decision(.automaticDownloads, for: site) == .allow)
        await store.flush()

        let relaunched = await loadedStore(FileSitePermissionPersistence(fileURL: file))
        let later = Asker()
        let newTab = gate(relaunched, later)
        #expect(await request(newTab, site))
        #expect(await request(newTab, site))
        #expect(later.asked.isEmpty)
    }

    /// Block is stored for the site: later automatic downloads are refused
    /// without a question, also after a relaunch.
    @Test func blockIsRememberedAndRefuses() async throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = await loadedStore(FileSitePermissionPersistence(fileURL: file))
        let asker = Asker()
        asker.answer = .deny
        let tab = gate(store, asker)
        #expect(await request(tab, site))
        // The held download is declined (listed blocked); later ones are
        // refused silently by the remembered Block.
        #expect(await outcome(tab, site) == .declined)
        #expect(await outcome(tab, site) == .refused)
        #expect(asker.asked == [site])
        #expect(store.decision(.automaticDownloads, for: site) == .block)
        await store.flush()

        let relaunched = await loadedStore(FileSitePermissionPersistence(fileURL: file))
        let later = Asker()
        let newTab = gate(relaunched, later)
        #expect(await request(newTab, site))
        #expect(!(await request(newTab, site)))
        #expect(later.asked.isEmpty)
    }

    @Test func aFreshGestureResetsTheCount() async {
        let asker = Asker()
        asker.answer = .deny
        let gate = gate(await loadedStore(), asker)
        #expect(await request(gate, site))
        gate.userGesture()
        #expect(await request(gate, site))
        #expect(asker.asked.isEmpty)
        #expect(!(await request(gate, site)))
        #expect(asker.asked == [site])
        // Blocked: a gesture still lets the next (first) download go ahead.
        gate.userGesture()
        #expect(await request(gate, site))
        #expect(!(await request(gate, site)))
        #expect(asker.asked == [site])
    }

    /// Counts and answers belong to one site: another site starts its own
    /// count and is asked its own question.
    @Test func sitesAreIsolated() async {
        let store = await loadedStore()
        let asker = Asker()
        asker.answer = .deny
        let gate = gate(store, asker)
        #expect(await request(gate, site))
        #expect(!(await request(gate, site)))
        #expect(await request(gate, other))
        asker.answer = .allow
        #expect(await request(gate, other))
        #expect(asker.asked == [site, other])
        #expect(store.decision(.automaticDownloads, for: site) == .block)
        #expect(store.decision(.automaticDownloads, for: other) == .allow)
    }

    /// A private profile's answer holds while it is open and never reaches
    /// a file; a normal profile's answer does.
    @Test func aPrivateProfileIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nx-autodl-private-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let offTheRecord = OffTheRecordProfiles()
        let registry = SiteSettingsRegistry(persistence: { profile in
            FileSitePermissionPersistence(fileURL: directory.appending(path: profile.rawValue.uuidString + ".json"))
        }, offTheRecord: offTheRecord)
        let privateProfile = offTheRecord.begin()
        let privateStore = registry.permissions(for: privateProfile)
        await privateStore.whenLoaded()
        let asker = Asker()
        asker.answer = .deny
        let tab = gate(privateStore, asker)
        #expect(await request(tab, site))
        #expect(!(await request(tab, site)))
        #expect(!(await request(tab, site)))
        #expect(asker.asked == [site])
        await privateStore.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: privateProfile.rawValue.uuidString + ".json")
            .path(percentEncoded: false)))

        let normalStore = registry.permissions(for: .default)
        await normalStore.whenLoaded()
        let normalTab = gate(normalStore, asker)
        #expect(await request(normalTab, site))
        #expect(!(await request(normalTab, site)))
        await normalStore.flush()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: BrowserProfileID.default.rawValue.uuidString + ".json")
            .path(percentEncoded: false)))
    }

    /// Closing the tab with the question open refuses the waiting download
    /// (listed blocked) and remembers nothing.
    @Test func aDismissedQuestionRemembersNothing() async {
        let prompt = BrowserPrompt(kind: .permission(.automaticDownloads), origin: site) { _ in }
        #expect(prompt.dismissalResponse == .cancel)
        let store = await loadedStore()
        let asker = Asker()
        asker.answer = prompt.dismissalResponse
        let gate = gate(store, asker)
        #expect(await request(gate, site))
        #expect(await outcome(gate, site) == .unanswered)
        #expect(store.decision(.automaticDownloads, for: site) == nil)
    }

    /// Fail-closed: a question that cannot show (no window, tab closed)
    /// refuses the held download at once, lists it blocked, and remembers
    /// nothing; the next download asks again.
    @Test func aQuestionThatCannotShowRefusesAtOnce() async {
        let store = await loadedStore()
        let asker = Asker()
        asker.canShow = false
        let gate = gate(store, asker)
        #expect(await request(gate, site))
        #expect(await outcome(gate, site) == .unanswered)
        #expect(await outcome(gate, site) == .unanswered)
        #expect(asker.asked == [site, site])
        #expect(store.decision(.automaticDownloads, for: site) == nil)
    }

    /// Downloads that arrive while the question is open wait for its one
    /// answer; a gesture meanwhile does not reset the count.
    @Test func downloadsWaitingForTheQuestionShareItsAnswer() async {
        let store = await loadedStore()
        var reply: ((BrowserPromptResponse) -> Void)?
        var asked = 0
        let gate = AutomaticDownloadGate(permissions: { store }, ask: { _, answer in
            asked += 1
            reply = answer
            return true
        })
        #expect(await request(gate, site))
        var results: [AutomaticDownloadGate.Outcome] = []
        gate.request(site: site) { results.append($0) }
        gate.request(site: site) { results.append($0) }
        // The question opens after the store's (already loaded) decisions are read.
        for _ in 0..<1000 where reply == nil { await Task.yield() }
        #expect(reply != nil)
        gate.userGesture()
        reply?(.deny)
        #expect(results == [.declined, .declined])
        #expect(asked == 1)
        // Still counting since the last gesture before the question: refused.
        #expect(!(await request(gate, site)))
    }
}
