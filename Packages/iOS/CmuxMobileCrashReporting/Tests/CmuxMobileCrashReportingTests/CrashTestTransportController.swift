import Foundation

@testable import CmuxMobileCrashReporting

final class CrashTestTransportController: MobileCrashTransportSessionControlling {
    let recorder: CrashTestSequenceRecorder
    let session = URLSession(configuration: .ephemeral)

    init(recorder: CrashTestSequenceRecorder) {
        self.recorder = recorder
    }

    func makeSession() -> URLSession {
        recorder.append("transport-start")
        return session
    }

    func invalidateAndCancel() {
        recorder.append("transport-cancel")
    }
}
