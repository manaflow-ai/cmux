@testable import CmuxAndroidBridge
import Foundation
import Testing

@Suite
struct SharedFrameBufferTests {
    @Test
    func rejectsDimensionsThatOverflowOrExceedTheFrameLimit() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path

        #expect(throws: BridgeFailure.self) {
            _ = try SharedFrameBuffer(path: path, maximumWidth: Int.max, maximumHeight: 2, slotCount: 3)
        }
        #expect(throws: BridgeFailure.self) {
            _ = try SharedFrameBuffer(path: path, maximumWidth: 8_192, maximumHeight: 8_192, slotCount: 3)
        }
    }
}
