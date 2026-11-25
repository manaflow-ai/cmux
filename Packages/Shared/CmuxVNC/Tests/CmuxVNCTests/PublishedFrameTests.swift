import Foundation
import Testing
@testable import CmuxVNC

struct PublishedFrameTests {
    @Test func publishingAnotherFramePreservesTheFirstFramesPixels() throws {
        let framebuffer = Framebuffer(width: 800, height: 450)
        let publisher = FramePublisher()
        framebuffer.fill(x: 0, y: 0, width: 400, height: 450, color: 0xFFFF_FFFF)
        framebuffer.fill(x: 400, y: 0, width: 400, height: 225, color: 0xFFFF_FFFF)
        let first = try #require(publisher.publish(framebuffer, dirty: framebuffer.takeDirty()))

        framebuffer.fill(x: 400, y: 225, width: 400, height: 225, color: 0xFFFF_FFFF)
        let second = try #require(publisher.publish(framebuffer, dirty: framebuffer.takeDirty()))

        #expect(first.sequence == 1 && second.sequence == 2)
        #expect(second.dirtyRect == CGRect(x: 400, y: 225, width: 400, height: 225))
        #expect(VNCScreenLayout().screens(in: second).isEmpty)
        #expect(VNCScreenLayout().screens(in: first) == [
            CGRect(x: 0, y: 0, width: 400, height: 450),
            CGRect(x: 400, y: 0, width: 400, height: 225),
        ])
    }
}
