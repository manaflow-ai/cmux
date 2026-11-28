import CmuxNextBrowserImport
@testable import CmuxNextImportCards
@testable import CmuxNextImportSuggestions
import CmuxNextTestSupport
import Foundation
import Testing

/// The Move this Mac to AutoCloud card in the center (#59280 F3, F1): its move runs as a tracked
/// job that ends with how many projects moved; a declined preview, or a host with no move, leaves
/// no job; a failure offers Try Again; and the card follows `cloud.autoCloud` without waiting for
/// the ten-minute rescan.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct ImportSuggestionsCenterAutoCloudTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let id = "cloud.moveThisMac"
    static let finding = ImportFinding(id: id, kind: .autoCloud, name: "Move This Mac to AutoCloud", count: 3)

    private struct Broke: Error {}

    /// `cloud.autoCloud` and the move's next outcome, as the test sets them.
    @MainActor final class Setting {
        var offered = true
        var outcomes: [Result<Int?, any Error>] = []
        private(set) var moves = 0

        func move() throws -> Int? {
            moves += 1
            return try outcomes.isEmpty ? nil : outcomes.removeFirst().get()
        }
    }

    /// A center whose scan finds the card while `setting.offered` (the scanner's rule), with
    /// `setting`'s move as the host's, or no move at all when `withMove` is false.
    private static func center(_ setting: Setting, withMove: Bool = true) async throws -> ImportSuggestionsCenter {
        let defaults = try #require(UserDefaults(testSuiteName: "import-center-\(UUID().uuidString)"))
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger, now: { Self.now })
        center.scanThisMac = { host in host.autoCloud?.offered() ?? true ? [Self.finding] : [] }
        let move = AutoCloudMove(offered: { setting.offered }, move: { _ in try setting.move() })
        center.host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] },
                                      openSettings: { _ in }, importClassic: { _ in nil }, importConductor: { _ in nil },
                                      classicAvailability: { .unavailable }, autoCloud: withMove ? move : nil)
        await withCheckedContinuation { done in center.scan { done.resume() } }
        return center
    }

    private static func card(_ center: ImportSuggestionsCenter) -> ImportCard? {
        center.list().cards.first { $0.id == id }
    }

    /// Waits (bounded) for the rescan in flight to land.
    private static func scanned(_ center: ImportSuggestionsCenter) async {
        for _ in 0..<10_000 where center.isScanning { await Task.yield() }
        #expect(!center.isScanning, "the rescan never landed")
    }

    @Test func aMoveEndsWithHowManyProjectsMoved() async throws {
        let setting = Setting()
        setting.outcomes = [.success(2)]
        let center = try await Self.center(setting)
        try center.perform(Self.id, .start)
        await center.settled(Self.id)
        #expect(center.ledger.job(Self.id)?.phase == .done)
        #expect(Self.card(center)?.status == ImportSuggestionStrings.movedProjects(2))
    }

    /// Cancel in the preview, or nothing left to move: no job is left and the card is as before.
    @Test func aDeclinedPreviewLeavesNoJob() async throws {
        let setting = Setting()
        setting.outcomes = [.success(nil)]
        let center = try await Self.center(setting)
        try center.perform(Self.id, .start)
        await center.settled(Self.id)
        #expect(setting.moves == 1)
        #expect(center.ledger.job(Self.id) == nil)
        let card = try #require(Self.card(center))
        #expect(card.state == .ready && card.primary?.action == .start)
    }

    /// A host without the move (`host.autoCloud` nil) moves nothing and leaves no job.
    @Test func aHostWithoutTheMoveLeavesNoJob() async throws {
        let setting = Setting()
        let center = try await Self.center(setting, withMove: false)
        try center.perform(Self.id, .start)
        await center.settled(Self.id)
        #expect(setting.moves == 0)
        #expect(center.ledger.job(Self.id) == nil)
    }

    /// A failed or unfinished move offers Try Again, which plans afresh.
    @Test func aFailedMoveOffersTryAgain() async throws {
        let setting = Setting()
        setting.outcomes = [.failure(MoveToAutoCloudFailure.unfinished(moved: 1, left: 1)), .success(1)]
        let center = try await Self.center(setting)
        try center.perform(Self.id, .start)
        await center.settled(Self.id)
        let job = try #require(center.ledger.job(Self.id))
        #expect(job.phase == .failed && job.failure == .importFailed)
        #expect(Self.card(center)?.primary?.action == .retry)
        try center.perform(Self.id, .retry)
        await center.settled(Self.id)
        #expect(setting.moves == 2 && Self.card(center)?.status == ImportSuggestionStrings.movedProjects(1))
    }

    /// #59280 F1: turning `cloud.autoCloud` on or off shows or hides the card when cmux comes
    /// forward, not at the next ten-minute rescan; unchanged, nothing rescans.
    @Test func theCardFollowsTheSettingAtOnce() async throws {
        let setting = Setting()
        setting.offered = false
        let center = try await Self.center(setting)
        #expect(Self.card(center) == nil)
        #expect(!center.refreshIfOfferChanged())

        setting.offered = true
        #expect(center.refreshIfOfferChanged())
        await Self.scanned(center)
        #expect(Self.card(center) != nil)

        setting.offered = false
        #expect(center.refreshIfOfferChanged())
        await Self.scanned(center)
        #expect(Self.card(center) == nil)
    }

    /// Settings › Import drawn again after the toggle (its section observes the setting) rescans too.
    @Test func settingsImportRescansWhenTheSettingChanged() async throws {
        let setting = Setting()
        setting.offered = false
        let center = try await Self.center(setting)
        setting.offered = true
        _ = center.settingsJSON
        for _ in 0..<10_000 where Self.card(center) == nil { await Task.yield() }
        #expect(Self.card(center) != nil)
    }
}
