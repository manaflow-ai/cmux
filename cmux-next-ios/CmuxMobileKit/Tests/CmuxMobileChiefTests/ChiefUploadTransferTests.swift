import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Leo (2026-11-24): "i also tried to send you a video and like it just blocked me endlessly on a
/// send". Every hop of a Cloud Chief upload is bounded and names itself when it fails; a large
/// file goes up in parts, a part that drops is tried again, and progress reaches the message.
@Suite(.serialized) struct ChiefUploadTransferTests {
    /// Answers each request with `Script.answer` (nil: never answers, as a dead link).
    final class Script: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var answer: @Sendable (URLRequest, Data) -> (Int, String)? = { _, _ in (200, "{}") }
        nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            let answer = Self.lock.withLock {
                Self.seen.append((request, body))
                return Self.answer
            }
            guard let reply = answer(request, body) else { return }
            let (status, text) = reply
            let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status,
                                           httpVersion: nil, headerFields: ["content-type": "application/json", "etag": "\"e\""])
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }

        static func reset(_ answer: @escaping @Sendable (URLRequest, Data) -> (Int, String)?) {
            lock.withLock {
                seen = []
                Self.answer = answer
            }
        }

        static func take() -> [(URLRequest, Data)] { lock.withLock { seen } }
    }

    static func http() throws -> ChiefCloudHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Script.self]
        var http = ChiefCloudHTTP(base: try #require(URL(string: "https://cloud-api-staging.cmux.dev")),
                                  accessToken: { _ in "token" }, session: URLSession(configuration: configuration),
                                  buildSpace: .nightly)
        http.uploadStall = .milliseconds(300)
        http.uploadRequestLimit = .milliseconds(300)
        return http
    }

    static func core(_ http: ChiefCloudHTTP) -> ChiefCloudBackend.Core {
        let name = "chief-upload-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ChiefCloudBackend.Core(http: http, conversationID: "conv_1", identity: .standard,
                                      preferences: ChiefPreferences(defaults: defaults), clock: ContinuousClock(),
                                      liveFeed: ChiefLiveFeed(), refused: { _ in })
    }

    @Test func aPutThatSendsNothingFailsNamingItsHop() async throws {
        Script.reset { _, _ in nil }
        let url = try #require(URL(string: "https://cloud-api-staging.cmux.dev/v1/home/attachments/multipart/c/t"))
        let started = ContinuousClock.now
        do {
            _ = try await Self.http().upload(url, method: "PUT", headers: [:], body: Data(repeating: 1, count: 64),
                                             toWorker: true, hop: "PUT part 2 of 4")
            Issue.record("a PUT nobody answers must not wait forever")
        } catch let failure as ChiefUpload.Failure {
            #expect(failure.hop == "PUT part 2 of 4")
            guard case .stalled = failure else { Issue.record("expected a stall, got \(failure)"); return }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func anIntentNobodyAnswersTimesOutNamingItsHop() async throws {
        Script.reset { _, _ in nil }
        do {
            _ = try await Self.http().sendBounded("the upload request", "POST", "/v1/home/attachments/intent", body: Data("{}".utf8))
            Issue.record("an intent nobody answers must not wait forever")
        } catch let failure as ChiefUpload.Failure {
            #expect(failure == .timedOut(hop: "the upload request", seconds: 0))
        }
    }

    @Test func boundedReturnsTheAnswerInTime() async throws {
        let value = try await ChiefUpload.bounded("hop", limit: .seconds(5)) { 7 }
        #expect(value == 7)
        await #expect(throws: ChiefUpload.Failure.timedOut(hop: "slow", seconds: 0)) {
            try await ChiefUpload.bounded("slow", limit: .milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
    }

    @Test func theFailureTellsThePersonWhichHopStopped() {
        let stalled = ChiefUpload.Failure.stalled(hop: "PUT part 3 of 4", sent: 10, seconds: 30)
        #expect(stalled.message.contains("PUT part 3 of 4"))
        #expect(stalled.message.contains("30"))
        #expect(ChiefUpload.isTransient(stalled))
        #expect(ChiefUpload.isTransient(URLError(.networkConnectionLost)))
        #expect(!ChiefUpload.isTransient(URLError(.cancelled)))
    }

    /// A 10-byte "video" in 4-byte parts: the intent asks for parts, each part names its number,
    /// part 2's first try drops (503) and is sent again, then the upload completes, progress
    /// climbs to 1 and the file comes back as a file attachment.
    @Test func aLargeFileGoesUpInPartsAndResumesADroppedPart() async throws {
        let data = Data((0..<10).map { UInt8($0) })
        let failedOnce = UploadTestBox(false)
        Script.reset { request, _ in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/intent") {
                return (200, """
                {"value":{"state":"upload","mode":"multipart","transport":"worker","method":"PUT",
                "upload_url":"https://cloud-api-staging.cmux.dev/v1/home/attachments/multipart/conv_1/tok",
                "headers":{"x-cmux-part-size":"4"},"part_size":4,"part_count":3,"slot":"slot_1"}}
                """)
            }
            if path.hasSuffix("/multipart/complete") { return (200, #"{"value":{"state":"done"}}"#) }
            let number = Int(request.value(forHTTPHeaderField: "x-cmux-part-number") ?? "") ?? 0
            if number == 2, !failedOnce.swap(true) { return (503, "{}") }
            let size = number == 3 ? 2 : 4
            return (200, #"{"value":{"part_number":\#(number),"byte_count":\#(size),"etag":"e\#(number)"}}"#)
        }
        let progress = UploadTestBox<[Double]>([])
        let info = ConversationFileInfo(name: "clip.mov", uti: "com.apple.quicktime-movie", byteCount: Int64(data.count))
        let attachment = try await ConversationUploadProgress.$report.withValue({ value in progress.mutate { $0.append(value) } }) {
            try await Self.core(try Self.http()).upload(data, mimeType: info.mimeType, name: info.name, width: 0, height: 0, file: info)
        }
        #expect(attachment.kind == .file)

        let seen = Script.take()
        let intent = try #require(seen.first)
        let asked = try #require(try JSONSerialization.jsonObject(with: intent.1) as? [String: Any])
        #expect(asked["multipart"] as? Bool == true)
        #expect(asked["byte_count"] as? Int == 10)
        let parts = seen.compactMap { $0.0.value(forHTTPHeaderField: "x-cmux-part-number") }
        #expect(parts == ["1", "2", "2", "3"])
        #expect(seen.allSatisfy { $0.0.value(forHTTPHeaderField: "x-cmux-part-number") == nil
                || $0.0.value(forHTTPHeaderField: "x-cmux-part-size") == "4" })
        let complete = try #require(seen.last)
        #expect(complete.0.url?.path.hasSuffix("/multipart/complete") == true)
        let completed = try #require(try JSONSerialization.jsonObject(with: complete.1) as? [String: Any])
        #expect((completed["parts"] as? [[String: Any]])?.count == 3)
        #expect(progress.value.first == 0)
        #expect(progress.value.last == 1)
    }

    /// A part whose every try stalls fails the send with the part's name, not a spinner.
    @Test func aPartThatKeepsStallingFailsTheSendWithItsName() async throws {
        Script.reset { request, _ in
            if request.url?.path.hasSuffix("/intent") == true {
                return (200, """
                {"value":{"state":"upload","mode":"multipart","transport":"worker","method":"PUT",
                "upload_url":"https://cloud-api-staging.cmux.dev/v1/home/attachments/multipart/conv_1/tok",
                "headers":{},"part_size":4,"part_count":1,"slot":"slot_1"}}
                """)
            }
            return nil
        }
        do {
            _ = try await Self.core(try Self.http()).upload(Data([1, 2, 3]), mimeType: "video/mp4", name: "a.mp4", width: 0, height: 0,
                                                            file: ConversationFileInfo(name: "a.mp4", uti: "public.mpeg-4", byteCount: 3))
            Issue.record("a stalled part must fail the send")
        } catch let error as ConversationBackendError {
            #expect(error.message.contains("PUT part 1 of 1"))
        }
        let tries = Script.take().filter { $0.0.value(forHTTPHeaderField: "x-cmux-part-number") == "1" }
        #expect(tries.count == ChiefUpload.attempts)
    }
}

/// A value several tasks touch in a test.
final class UploadTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
    /// Sets `new`, answering the value before.
    func swap(_ new: Value) -> Value { lock.withLock { defer { stored = new }; return stored } }
}
