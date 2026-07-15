import Foundation
import Testing
@testable import CmuxSimulator

@Suite("SimulatorRenderedFrame")
struct SimulatorRenderedFrameTests {
    @Test func decodesPNGBytesToABitmapAndKeepsSequence() throws {
        let frame = SimulatorDisplayFrame(imageData: SimulatorFixtures.onePixelPNG, sequence: 7)
        let rendered = try #require(SimulatorRenderedFrame(decoding: frame))
        #expect(rendered.sequence == 7)
        #expect(rendered.image.width == 1)
        #expect(rendered.image.height == 1)
    }

    @Test func nonImageBytesDecodeToNil() {
        let frame = SimulatorDisplayFrame(imageData: Data("not a png".utf8), sequence: 1)
        #expect(SimulatorRenderedFrame(decoding: frame) == nil)
    }
}
