import AppKit
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// User 2026-11-20 ("get rid of this", a screenshot of the Home header): the location chip beside the
/// Chief's name ("This Mac + Cloud fork") sat over the name in the header. Where the Chief runs now
/// shows only in the Chief card's Runs On row, whose chip keeps the Teleport menu (move, roll back,
/// the Cloud fork's line).
@MainActor struct ChiefRunsOnChipTests {
    /// What one `follow` placed, the first time it placed anything.
    @MainActor final class Placed {
        var views: [NSView]?
    }

    private static let fork = ChiefForkRecord(name: "Chief fork", chief: "agent_fork", at: Date(timeIntervalSince1970: 1_793_980_931))

    @Test func onlyTheCardsRunsOnRowGetsAChip() async {
        let model = ChiefTeleportModel(showing: .thisMac, phase: .idle, destinations: [], fork: Self.fork)
        let runsOn = ChiefRunsOnChip(model: model)
        let owner = NSView()
        let placed = Placed()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            runsOn.follow(for: owner, { true }) { card in
                guard placed.views == nil else { return }
                placed.views = [card].compactMap { $0 }
                done.resume()
            }
        }
        let ids = placed.views?.map { $0.accessibilityIdentifier() } ?? []
        #expect(ids == ["cmux.home.chief.teleport.card"], "the header gets no location chip; only the card's Runs On row has one: \(ids)")
        withExtendedLifetime(owner) {}
    }
}
