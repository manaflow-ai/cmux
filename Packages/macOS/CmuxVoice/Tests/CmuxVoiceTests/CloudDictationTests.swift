import Foundation
import Testing

@testable import CmuxVoice

private final class RequestBox: @unchecked Sendable {
    var request: URLRequest?
}

private func response(status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: OpenAITranscriptionClient.endpoint,
        statusCode: status,
        httpVersion: nil,
        headerFields: nil
    )!
}

struct OpenAITranscriptionClientTests {
    @Test func requestCarriesKeyModelAndClip() throws {
        let client = OpenAITranscriptionClient(apiKey: "test-key", model: "test-model")
        let wav = Data([1, 2, 3, 4])
        let request = client.makeRequest(wav: wav, boundary: "B")

        #expect(request.url == OpenAITranscriptionClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"model\"\r\n\r\ntest-model\r\n"))
        #expect(text.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(text.contains("filename=\"dictation.wav\""))
        #expect(text.hasSuffix("\r\n--B--\r\n"))
        #expect(body.range(of: wav) != nil)
    }

    @Test func successReturnsTrimmedText() async throws {
        let box = RequestBox()
        let client = OpenAITranscriptionClient(apiKey: "k") { request in
            box.request = request
            return (Data(#"{"text":"  fix the build \n"}"#.utf8), response(status: 200))
        }
        let text = try await client.transcribe(wav: Data([0, 0]))
        #expect(text == "fix the build")
        #expect(box.request?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func httpErrorSurfacesServerMessage() async {
        let client = OpenAITranscriptionClient(apiKey: "bad") { _ in
            (Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8), response(status: 401))
        }
        await #expect(throws: DictationFailure.cloudTranscriptionFailed("HTTP 401: Incorrect API key provided")) {
            try await client.transcribe(wav: Data())
        }
    }

    @Test func unreadableBodyFails() async {
        let client = OpenAITranscriptionClient(apiKey: "k") { _ in
            (Data("<html>".utf8), response(status: 200))
        }
        await #expect(throws: DictationFailure.cloudTranscriptionFailed("unreadable response")) {
            try await client.transcribe(wav: Data())
        }
    }

    @Test func errorMessageWithoutJSONFallsBackToStatus() {
        #expect(OpenAITranscriptionClient.errorMessage(status: 502, body: Data("gateway".utf8)) == "HTTP 502")
    }
}

struct DictationWAVEncoderTests {
    @Test func headerDescribesMono16BitPCM() {
        let samples = Data([0x01, 0x00, 0xFF, 0x7F])
        let wav = DictationWAVEncoder.wav(pcm16: samples, sampleRate: 16_000)

        func uint32(at offset: Int) -> UInt32 {
            wav[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        func uint16(at offset: Int) -> UInt16 {
            UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8
        }

        #expect(wav.count == 44 + samples.count)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(at: 4) == UInt32(36 + samples.count))
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(uint16(at: 20) == 1)
        #expect(uint16(at: 22) == 1)
        #expect(uint32(at: 24) == 16_000)
        #expect(uint32(at: 28) == 32_000)
        #expect(uint16(at: 34) == 16)
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(uint32(at: 40) == UInt32(samples.count))
        #expect(wav.suffix(4) == samples)
    }
}

struct DictationAudioLevelMeterTests {
    @Test func normalizesDecibelsIntoUnitRange() {
        #expect(DictationAudioLevelMeter.normalizedLevel(rms: 0) == 0)
        #expect(DictationAudioLevelMeter.normalizedLevel(rms: .nan) == 0)
        #expect(DictationAudioLevelMeter.normalizedLevel(rms: 1) == 1)
        #expect(DictationAudioLevelMeter.normalizedLevel(rms: 2) == 1)
        #expect(DictationAudioLevelMeter.normalizedLevel(rms: 0.000_001) == 0)
        let mid = DictationAudioLevelMeter.normalizedLevel(rms: 0.01)
        #expect(mid > 0.2 && mid < 0.4)
    }

    @Test func attacksFastReleasesSlowAndResets() {
        let meter = DictationAudioLevelMeter()
        meter.update(rms: 1)
        #expect(meter.level == 1)
        meter.update(rms: 0)
        #expect(meter.level > 0.5 && meter.level < 1)
        meter.reset()
        #expect(meter.level == 0)
    }
}

struct DictationTextCleanupTests {
    @Test(arguments: [
        ("um so, uh, fix the build", "so, fix the build"),
        ("Um, let's go.", "Let's go."),
        ("uh", ""),
        ("rename it, uh.", "rename it."),
        ("Summary um of errors", "Summary of errors"),
        ("run the tests", "run the tests"),
        ("summarize the umbrella hummus", "summarize the umbrella hummus"),
        ("Um, git status", "git status"),
        ("set it to 20 um", "set it to 20 um"),
        ("make it 5 mm wider", "make it 5 mm wider"),
        ("line one\n  indented  um  here", "line one\n  indented  here"),
        (" uh okay", " okay"),
    ])
    func dropsFillers(input: String, expected: String) {
        #expect(input.removingDictationFillers == expected)
    }

    @Test func onlyAppliesToEnglish() {
        #expect(Locale(identifier: "en_GB").supportsDictationFillerCleanup)
        #expect(!Locale(identifier: "pt_BR").supportsDictationFillerCleanup)
        #expect(!Locale(identifier: "de_DE").supportsDictationFillerCleanup)
    }
}

struct FixtureDictationTranscriberTests {
    @Test func splitsScriptIntoSentences() {
        #expect(
            FixtureDictationTranscriber.sentences(in: "Fix the build. Then run tests?\nShip it")
                == ["Fix the build.", "Then run tests?", "Ship it"]
        )
        #expect(FixtureDictationTranscriber.sentences(in: "  ").isEmpty)
    }
}

struct CloudDictationTranscriberTests {
    @Test func startsWithBaseStopDeadline() {
        let cloud = CloudDictationTranscriber(client: OpenAITranscriptionClient(apiKey: "k"))
        #expect(cloud.stopDeadline == .seconds(CloudDictationTranscriber.stopDeadlineBase))
        #expect(cloud.stopDeadline > .seconds(3))
    }
}
