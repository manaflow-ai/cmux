import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// The phone's snapshot ends with the replay's unfinished sequence, after
/// the cursor shape, so the phone's next live chunk completes it.
@Suite struct MobileCompatReplayBytesTests {
    @Test func pendingSequenceGoesLast() throws {
        let colors = try JSONDecoder().decode(TerminalColors.self, from: Data(#"{"cursor_style":"bar","cursor_blink":false}"#.utf8))
        let replay = TerminalReplay(cols: 80, rows: 24, data: Data("prompt$ ".utf8), colors: colors,
                                    pending: Data("\u{1B}[1;3".utf8))
        let snapshot = MobileCompatReplayBytes.snapshot(replay)
        #expect(snapshot.suffix(10) == Data("\u{1B}[6 q\u{1B}[1;3".utf8))
        #expect(MobileCompatReplayBytes.replacement(replay).suffix(5) == Data("\u{1B}[1;3".utf8))
    }
}
