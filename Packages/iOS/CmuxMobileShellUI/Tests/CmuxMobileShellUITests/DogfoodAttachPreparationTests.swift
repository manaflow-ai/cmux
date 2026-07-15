import Testing
@testable import CmuxMobileShellUI

@Suite
struct DogfoodAttachPreparationTests {
    @Test
    @MainActor
    func waitsForTransportReadinessBeforeConsumingAttachURL() async {
        let recorder = DogfoodAttachPreparationRecorder()
        let preparation = DogfoodAttachPreparation {
            await recorder.record("ready")
        }

        await preparation.run {
            await recorder.record("attach")
        }

        #expect(await recorder.values() == ["ready", "attach"])
    }
}

private actor DogfoodAttachPreparationRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}
