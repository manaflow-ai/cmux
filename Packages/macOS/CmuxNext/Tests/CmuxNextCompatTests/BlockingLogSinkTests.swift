import CmuxNextCompat
import Foundation
import Testing

/// The shipped detector's sink (Nightly): one public line per new call site with the kind and the
/// UUID + offset frames only.
@Suite struct BlockingLogSinkTests {
    final class Lines: Sendable {
        let value = Mutex<[String]>([])
    }

    @Test func aViolationIsOneLineOfKindAndFrames() {
        let lines = Lines()
        let sink = BlockingLogSink { line in lines.value.withLock { $0.append(line) } }
        let uuid = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000ABCD")!
        sink.record(BlockingViolation(kind: .fileIO, frames: [BlockingFrame(imageUUID: uuid, offset: 0x1f40),
                                                              BlockingFrame(imageUUID: uuid, offset: 0x20)]))
        sink.record(BlockingViolation(kind: .fileIO, frames: []))
        #expect(lines.value.withLock { $0 } == [
            "blocking \(BlockingKind.fileIO.rawValue) on the main thread; frames "
                + "0A1B2C3D-0000-4000-8000-00000000ABCD+0x1f40 0A1B2C3D-0000-4000-8000-00000000ABCD+0x20",
            "blocking \(BlockingKind.fileIO.rawValue) on the main thread; frames none",
        ])
    }
}
