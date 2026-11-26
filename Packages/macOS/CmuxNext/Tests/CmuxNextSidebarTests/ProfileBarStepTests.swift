@testable import CmuxNextSidebar
import Testing

/// Next / Previous space (swipe, keys) from a window whose current space is not in the strip: none yet, or it was
/// just deleted. The step used to count that as the first space, so Next skipped the first space and Previous did nothing.
@Suite struct ProfileBarStepTests {
    let order = [ProfileKey("a"), ProfileKey("b"), ProfileKey("c")]

    @Test func nextWithNoCurrentSpaceLandsOnTheFirst() {
        #expect(ProfileBarLogic.step(from: nil, by: 1, in: order) == ProfileKey("a"))
        #expect(ProfileBarLogic.step(from: ProfileKey("gone"), by: 1, in: order) == ProfileKey("a"))
    }

    @Test func previousWithNoCurrentSpaceLandsOnTheLast() {
        #expect(ProfileBarLogic.step(from: nil, by: -1, in: order) == ProfileKey("c"))
        #expect(ProfileBarLogic.step(from: ProfileKey("gone"), by: -1, in: order) == ProfileKey("c"))
    }

    @Test func aLongStepWithNoCurrentSpaceClampsAtTheEnds() {
        #expect(ProfileBarLogic.step(from: nil, by: 2, in: order) == ProfileKey("b"))
        #expect(ProfileBarLogic.step(from: nil, by: 9, in: order) == ProfileKey("c"))
        #expect(ProfileBarLogic.step(from: nil, by: -9, in: order) == ProfileKey("a"))
    }

    @Test func aKnownCurrentSpaceStillStepsAndClamps() {
        #expect(ProfileBarLogic.step(from: ProfileKey("a"), by: 1, in: order) == ProfileKey("b"))
        #expect(ProfileBarLogic.step(from: ProfileKey("a"), by: -1, in: order) == nil)
        #expect(ProfileBarLogic.step(from: ProfileKey("c"), by: 1, in: order) == nil)
        #expect(ProfileBarLogic.step(from: nil, by: 0, in: order) == nil)
        #expect(ProfileBarLogic.step(from: nil, by: 1, in: []) == nil)
    }
}
