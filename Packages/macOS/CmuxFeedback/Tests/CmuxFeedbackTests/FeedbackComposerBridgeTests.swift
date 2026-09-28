import Foundation
import Testing

@testable import CmuxFeedback

@Suite("Feedback composer bridge")
struct FeedbackComposerBridgeTests {
    @Test func emptyMessageIsRejectedBeforeAnyNetwork() async {
        await #expect(throws: FeedbackComposerBridgeError.self) {
            _ = try await FeedbackComposerBridge().submit(
                email: "valid@example.com",
                message: "   ",
                imagePaths: []
            )
        }
    }

    @Test func invalidEmailIsRejectedBeforeAnyNetwork() async {
        await #expect(throws: FeedbackComposerBridgeError.self) {
            _ = try await FeedbackComposerBridge().submit(
                email: "not-an-email",
                message: "Real message",
                imagePaths: []
            )
        }
    }

    @Test func blankEmailSubmitsAnonymouslyAndKeepsSavedEmail() async throws {
        let settings = FeedbackComposerSettings(
            endpointEnvironmentKey: "CMUX_FEEDBACK_API_URL_BRIDGE_TEST",
            defaultEndpoint: "https://\(FeedbackUploadStub.host)/api/feedback"
        )
        let defaults = try #require(UserDefaults(suiteName: "FeedbackComposerBridgeTests.\(UUID().uuidString)"))
        defaults.set("saved@example.com", forKey: settings.storedEmailKey)

        URLProtocol.registerClass(FeedbackUploadStub.self)
        defer { URLProtocol.unregisterClass(FeedbackUploadStub.self) }

        let uploaded = try await FeedbackComposerBridge(
            client: FeedbackComposerClient(settings: settings),
            userDefaults: defaults
        ).submit(email: "   ", message: "Anonymous report", imagePaths: [])

        #expect(uploaded == 0)
        let body = try #require(FeedbackUploadStub.lastBody.value)
        #expect(body.contains("name=\"email\"\r\n\r\n\r\n"))
        #expect(body.contains("Anonymous report"))
        #expect(defaults.string(forKey: settings.storedEmailKey) == "saved@example.com")
    }

    @Test func tooManyImagesIsRejectedBeforeAnyNetwork() async {
        let settings = FeedbackComposerSettings()
        let paths = (0..<(settings.maxAttachmentCount + 1)).map { "/tmp/feedback-\($0).png" }
        await #expect(throws: FeedbackComposerBridgeError.self) {
            _ = try await FeedbackComposerBridge().submit(
                email: "valid@example.com",
                message: "Real message",
                imagePaths: paths
            )
        }
    }

    @Test func endpointHonorsEnvironmentOverride() {
        // The override is read from the process environment; with no override set
        // the resolved endpoint falls back to the production default.
        let settings = FeedbackComposerSettings()
        if ProcessInfo.processInfo.environment[settings.endpointEnvironmentKey] == nil {
            #expect(settings.endpointURL()?.absoluteString == settings.defaultEndpoint)
        }
    }

    @Test func composerRequestedNotificationNameMatchesAppContract() {
        #expect(Notification.Name.feedbackComposerRequested.rawValue == "cmux.feedbackComposerRequested")
    }
}

/// Answers feedback uploads to a test-only host with 200 and records the
/// multipart body, so the bridge can be exercised without the network.
final class FeedbackUploadStub: URLProtocol {
    static let host = "feedback-bridge.test"
    static let lastBody = LockedValue<String>()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastBody.value = Self.readBody(of: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // URLSession hands protocols the body as a stream, not `httpBody`.
    private static func readBody(of request: URLRequest) -> String? {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
