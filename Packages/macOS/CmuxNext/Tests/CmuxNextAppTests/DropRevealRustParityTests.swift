import CmuxNextAppCore
import CmuxNextBridge
import CoreGraphics
import Foundation
import Testing

/// The pre-migration Swift policy is retained here as a test oracle. The
/// production policy is Rust-only; this helper is deliberately test-scoped.
private enum OriginalDropRevealPolicy {
    struct Facts {
        var outcome: TabDragOutcome
        var landed: Bool
        var userInitiated: Bool
        var focusRequested: Bool = false
        var filesAway: Bool = false
        var crossesWindows: Bool = false
        var appActive: Bool = true
        var noActivate: Bool = false
        var landingOnActiveSpace: Bool = true
    }

    static func decide(_ facts: Facts) -> (focusesTab: Bool, showsWorkspace: Bool, makesKey: Bool)? {
        guard facts.landed, !facts.filesAway, facts.userInitiated || facts.focusRequested else { return nil }
        let showsWorkspace: Bool
        let newWindow: Bool
        switch facts.outcome {
        case .cancel, .moveWindow, .moveWorkspaceToNewWindow, .moveWorkspace:
            return nil
        case .strip, .newSplit, .newColumn, .newDock:
            showsWorkspace = false
            newWindow = false
        case .newWorkspace, .workspace:
            showsWorkspace = true
            newWindow = false
        case .tearOff:
            showsWorkspace = true
            newWindow = true
        }
        let keyable = facts.appActive && !facts.noActivate && facts.landingOnActiveSpace
        return (true, showsWorkspace, (newWindow || facts.crossesWindows) && keyable)
    }
}

struct DropRevealRustParityTests {
    private static let outcomes: [TabDragOutcome] = [
        .cancel,
        .strip(stripID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, index: 0, groupID: nil),
        .newSplit(paneID: "pane", edge: .left),
        .newColumn(screenID: "screen", afterColumnID: "column"),
        .newDock(screenID: "screen", edge: "top"),
        .newWorkspace(groupID: nil, index: nil),
        .workspace(id: "workspace"),
        .tearOff(screenPoint: CGPoint(x: 1, y: 2)),
        .moveWindow(screenPoint: CGPoint(x: 1, y: 2)),
        .moveWorkspaceToNewWindow(screenPoint: CGPoint(x: 1, y: 2)),
        .moveWorkspace(groupID: nil, index: nil),
    ]

    private static func candidate(_ facts: OriginalDropRevealPolicy.Facts) -> (Bool, Bool, Bool)? {
        let publicFacts = DropRevealPolicy.Facts(
            outcome: facts.outcome,
            landed: facts.landed,
            userInitiated: facts.userInitiated,
            focusRequested: facts.focusRequested,
            filesAway: facts.filesAway,
            crossesWindows: facts.crossesWindows,
            appActive: facts.appActive,
            noActivate: facts.noActivate,
            landingOnActiveSpace: facts.landingOnActiveSpace
        )
        return DropRevealPolicy.decide(publicFacts).map { ($0.focusesTab, $0.showsWorkspace, $0.makesKey) }
    }

    @Test
    func rustPolicyMatchesOriginalForEveryOutcomeAndBooleanCombination() {
        var cases = 0
        for outcome in Self.outcomes {
            for mask in 0..<256 {
                let bit: (Int) -> Bool = { mask & (1 << $0) != 0 }
                let facts = OriginalDropRevealPolicy.Facts(
                    outcome: outcome,
                    landed: bit(0),
                    userInitiated: bit(1),
                    focusRequested: bit(2),
                    filesAway: bit(3),
                    crossesWindows: bit(4),
                    appActive: bit(5),
                    noActivate: bit(6),
                    landingOnActiveSpace: bit(7)
                )
                let expected = OriginalDropRevealPolicy.decide(facts)
                let actual = Self.candidate(facts)
                #expect(actual?.0 == expected?.focusesTab)
                #expect(actual?.1 == expected?.showsWorkspace)
                #expect(actual?.2 == expected?.makesKey)
                #expect((actual == nil) == (expected == nil), "outcome=\(outcome), mask=\(mask)")
                cases += 1
            }
        }
        #expect(cases == 11 * 256)
    }
}
