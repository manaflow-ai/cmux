import CmuxChiefVoiceCore
import Foundation

struct FakeError: Error {}

actor FakeRecorder: VoiceRecording {
    private(set) var startedURLs: [URL] = []
    private(set) var stops = 0
    var failStart = false

    func setFailStart(_ value: Bool) { failStart = value }

    func start(writingTo url: URL) async throws {
        if failStart { throw FakeError() }
        startedURLs.append(url)
        try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
    }

    func stop() async -> TimeInterval {
        stops += 1
        return 3.5
    }
}

actor FakeTranscriber: VoiceTranscribing {
    var result: Result<String, FakeError> = .success("Hello Chief, ship the build.")

    func set(_ result: Result<String, FakeError>) { self.result = result }

    func transcribe(fileAt url: URL) async throws -> String { try result.get() }
}

struct FakeMicrophone: MicrophoneAuthorizing {
    var granted = true
    func requestAccess() async -> Bool { granted }
}

actor FakeDelivery: ChiefVoiceDelivering {
    struct Delivered: Sendable {
        var note: VoiceNote
        var audioExisted: Bool
    }

    private(set) var delivered: [Delivered] = []
    var reachable = true

    func setReachable(_ value: Bool) { reachable = value }

    func deliver(_ note: VoiceNote, audioURL: URL) async throws {
        guard reachable else { throw FakeError() }
        delivered.append(Delivered(note: note, audioExisted: FileManager().fileExists(atPath: audioURL.path)))
    }
}

func temporaryDirectory() -> URL {
    FileManager().temporaryDirectory.appendingPathComponent("chief-voice-\(UUID().uuidString)", isDirectory: true)
}
