import Testing

@testable import CmuxFoundation

@Suite struct JumpToBottomAffordanceTests {
    private func snapshot(
        below: UInt64,
        length: UInt64 = 200,
        layout: Int = 80
    ) -> JumpToBottomAffordance.Snapshot {
        .init(distanceFromBottom: below, contentLength: length, layoutKey: layout)
    }

    @Test func hiddenAtBottomWithoutAskingTheContentOwner() {
        var affordance = JumpToBottomAffordance()
        var ownerChecks = 0
        let changed = affordance.update(snapshot(below: 0), isEnabled: true) {
            ownerChecks += 1
            return false
        }
        #expect(!changed)
        #expect(!affordance.isVisible)
        #expect(ownerChecks == 0)
    }

    @Test func showsWhenTheViewportLeavesTheBottomAndHidesWhenItReturns() {
        var affordance = JumpToBottomAffordance()
        #expect(affordance.update(snapshot(below: 12), isEnabled: true) { false })
        #expect(affordance.isVisible)
        #expect(!affordance.update(snapshot(below: 30), isEnabled: true) { false })
        #expect(affordance.update(snapshot(below: 0), isEnabled: true) { false })
        #expect(!affordance.isVisible)
    }

    @Test func missingGeometryHides() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 5), isEnabled: true) { false }
        #expect(affordance.update(nil, isEnabled: true) { false })
        #expect(!affordance.isVisible)
    }

    @Test func contentThatOwnsScrollingSuppressesTheAffordance() {
        var affordance = JumpToBottomAffordance()
        var ownerChecks = 0
        let ownsScrolling = {
            ownerChecks += 1
            return true
        }
        #expect(!affordance.update(snapshot(below: 8), isEnabled: true, contentOwnsScrolling: ownsScrolling))
        #expect(!affordance.update(snapshot(below: 9), isEnabled: true, contentOwnsScrolling: ownsScrolling))
        #expect(!affordance.isVisible)
        // The owner is asked once per departure from the bottom, not per snapshot.
        #expect(ownerChecks == 1)

        affordance.update(snapshot(below: 0), isEnabled: true, contentOwnsScrolling: ownsScrolling)
        affordance.update(snapshot(below: 4), isEnabled: true) { false }
        #expect(affordance.isVisible)
    }

    @Test func ownerIsCheckedOnlyWhenTheAffordanceWouldAppear() {
        var affordance = JumpToBottomAffordance()
        var ownerChecks = 0
        let check = {
            ownerChecks += 1
            return false
        }
        affordance.update(snapshot(below: 3), isEnabled: true, contentOwnsScrolling: check)
        affordance.update(snapshot(below: 40), isEnabled: true, contentOwnsScrolling: check)
        affordance.update(snapshot(below: 2), isEnabled: true, contentOwnsScrolling: check)
        #expect(ownerChecks == 1)
    }

    @Test func disabledSettingHidesAndReenablingShowsAgain() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 6), isEnabled: true) { false }
        #expect(affordance.update(snapshot(below: 6), isEnabled: false) { false })
        #expect(!affordance.isVisible)
        #expect(affordance.update(snapshot(below: 6), isEnabled: true) { false })
        #expect(affordance.isVisible)
    }

    @Test func reenablingDoesNotResurfaceOverContentThatOwnsScrolling() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 6), isEnabled: true) { true }
        affordance.update(snapshot(below: 6), isEnabled: false) { true }
        var ownerChecks = 0
        affordance.update(snapshot(below: 6), isEnabled: true) {
            ownerChecks += 1
            return false
        }
        #expect(!affordance.isVisible)
        #expect(ownerChecks == 0)
    }

    @Test func contentGrowthBelowTheViewportMarksNewContent() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 10, length: 200), isEnabled: true) { false }
        #expect(!affordance.hasNewContentBelow)
        #expect(affordance.update(snapshot(below: 14, length: 204), isEnabled: true) { false })
        #expect(affordance.hasNewContentBelow)

        affordance.update(snapshot(below: 0, length: 204), isEnabled: true) { false }
        #expect(!affordance.hasNewContentBelow)
        affordance.update(snapshot(below: 10, length: 204), isEnabled: true) { false }
        #expect(!affordance.hasNewContentBelow)
    }

    @Test func scrollingWithoutNewContentDoesNotMarkNewContent() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 10, length: 200), isEnabled: true) { false }
        affordance.update(snapshot(below: 50, length: 200), isEnabled: true) { false }
        affordance.update(snapshot(below: 3, length: 200), isEnabled: true) { false }
        #expect(affordance.isVisible)
        #expect(!affordance.hasNewContentBelow)
    }

    @Test func relayoutIsNotNewContent() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 10, length: 200, layout: 80), isEnabled: true) { false }
        affordance.update(snapshot(below: 25, length: 260, layout: 60), isEnabled: true) { false }
        #expect(!affordance.hasNewContentBelow)
        affordance.update(snapshot(below: 27, length: 262, layout: 60), isEnabled: true) { false }
        #expect(affordance.hasNewContentBelow)
    }

    @Test func trimmedContentMeasuresLaterGrowthFromTheSmallerLength() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 10, length: 200), isEnabled: true) { false }
        affordance.update(snapshot(below: 10, length: 150), isEnabled: true) { false }
        #expect(!affordance.hasNewContentBelow)
        affordance.update(snapshot(below: 12, length: 152), isEnabled: true) { false }
        #expect(affordance.hasNewContentBelow)
    }

    @Test func resetForgetsEverything() {
        var affordance = JumpToBottomAffordance()
        affordance.update(snapshot(below: 10, length: 200), isEnabled: true) { false }
        affordance.update(snapshot(below: 12, length: 202), isEnabled: true) { false }
        affordance.reset()
        #expect(affordance == JumpToBottomAffordance())
    }
}
