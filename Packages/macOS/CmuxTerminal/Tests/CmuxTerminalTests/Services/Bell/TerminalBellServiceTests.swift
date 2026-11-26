import AppKit
import Testing
@testable import CmuxTerminal

@MainActor
@Suite("Terminal bell service")
struct TerminalBellServiceTests {
    @Test
    func playsOnlyExplicitAudioEffects() {
        var systemBeepCount = 0
        var loadedPaths: [String] = []
        let service = TerminalBellService(
            systemBeep: { systemBeepCount += 1 },
            soundLoader: {
                loadedPaths.append($0)
                return nil
            }
        )

        service.ring(presentation: TerminalBellPresentation(
            systemSoundEnabled: false,
            customAudioPath: nil,
            customAudioVolume: 0.5,
            visualBellEnabled: true
        ))
        #expect(systemBeepCount == 0)
        #expect(loadedPaths.isEmpty)

        service.ring(presentation: TerminalBellPresentation(
            systemSoundEnabled: true,
            customAudioPath: nil,
            customAudioVolume: 0.5,
            visualBellEnabled: false
        ))
        #expect(systemBeepCount == 1)
        #expect(loadedPaths.isEmpty)

        service.ring(presentation: TerminalBellPresentation(
            systemSoundEnabled: false,
            customAudioPath: "/tmp/cmux-terminal-bell.aiff",
            customAudioVolume: 0.25,
            visualBellEnabled: false
        ))
        #expect(systemBeepCount == 1)
        #expect(loadedPaths == ["/tmp/cmux-terminal-bell.aiff"])
    }
}
