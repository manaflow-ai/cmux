import Testing

@testable import CmuxPanes

@Suite("SplitDirection control-token parsing")
struct SplitDirectionControlTokenTests {
    @Test("Long and short tokens map to each case, case-insensitively")
    func parsesKnownTokens() {
        #expect(SplitDirection(controlToken: "left") == .left)
        #expect(SplitDirection(controlToken: "l") == .left)
        #expect(SplitDirection(controlToken: "LEFT") == .left)
        #expect(SplitDirection(controlToken: "right") == .right)
        #expect(SplitDirection(controlToken: "r") == .right)
        #expect(SplitDirection(controlToken: "up") == .up)
        #expect(SplitDirection(controlToken: "u") == .up)
        #expect(SplitDirection(controlToken: "down") == .down)
        #expect(SplitDirection(controlToken: "D") == .down)
    }

    @Test("Unknown tokens return nil")
    func rejectsUnknownTokens() {
        #expect(SplitDirection(controlToken: "") == nil)
        #expect(SplitDirection(controlToken: "diagonal") == nil)
        #expect(SplitDirection(controlToken: "top") == nil)
        #expect(SplitDirection(controlToken: " left") == nil)
    }
}
