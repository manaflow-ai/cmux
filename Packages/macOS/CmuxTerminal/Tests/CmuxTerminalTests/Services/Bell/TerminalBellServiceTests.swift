import AppKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite("Terminal bell service")
struct TerminalBellServiceTests {
    @Test
    func playsOnlyExplicitAudioEffects() {
        let recorder = TerminalBellAudioRecorder()
        let service = TerminalBellService(
            systemBeep: { recorder.systemBeepCount += 1 },
            soundLoader: {
                recorder.loadedPaths.append($0)
                return nil
            }
        )

        service.ring(
            systemSoundEnabled: false,
            customAudioPath: nil,
            customAudioVolume: 0.5
        )
        #expect(recorder.systemBeepCount == 0)
        #expect(recorder.loadedPaths.isEmpty)

        service.ring(
            systemSoundEnabled: true,
            customAudioPath: nil,
            customAudioVolume: 0.5
        )
        #expect(recorder.systemBeepCount == 1)
        #expect(recorder.loadedPaths.isEmpty)

        service.ring(
            systemSoundEnabled: false,
            customAudioPath: "/tmp/cmux-terminal-bell.aiff",
            customAudioVolume: 0.25
        )
        #expect(recorder.systemBeepCount == 1)
        #expect(recorder.loadedPaths == ["/tmp/cmux-terminal-bell.aiff"])
    }
}

@MainActor
private final class TerminalBellAudioRecorder {
    var systemBeepCount = 0
    var loadedPaths: [String] = []
}
