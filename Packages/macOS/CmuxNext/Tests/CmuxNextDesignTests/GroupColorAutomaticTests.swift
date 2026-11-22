import CmuxNextDesign
import Testing

/// A new space or browser profile gets the next free group color
/// automatically. The automatic pick never is blue (the no-blue rule:
/// Ghostty colors only, nxdog63-v2) or grey (the "no color" look); a user
/// can still choose blue on purpose.
@Suite struct GroupColorAutomaticTests {
    @Test func theFirstAutomaticColorIsNotBlue() {
        #expect(GroupColor.automatic(used: []) != .blue)
        #expect(GroupColor.automatic(used: []) != .grey)
    }

    @Test func theAutomaticPickSkipsUsedColorsAndNeverPicksBlueOrGrey() {
        var used: Set<String> = []
        while let next = GroupColor.automatic(used: used) {
            #expect(next != .blue && next != .grey, "\(next)")
            #expect(!used.contains(next.rawValue))
            used.insert(next.rawValue)
        }
        #expect(used.count == GroupColor.allCases.count - 2, "every other color is used once: \(used)")
    }
}
