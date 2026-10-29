#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// With `CMUX_NEXT_SENTRY_RECORDER=<dir>` an event lands as an envelope file in `<dir>`,
/// scrubbed and labeled as Sentry would receive it, and nothing is sent.
@Suite struct SentryRecorderTransportTests {
    @Test func theEnvironmentNamesTheDirectory() {
        #expect(SentryRecorderTransport(environment: [:]) == nil)
        #expect(SentryRecorderTransport(environment: [SentryRecorderTransport.environmentKey: ""]) == nil)
        let recorder = SentryRecorderTransport(environment: [SentryRecorderTransport.environmentKey: "/tmp/rec"])
        #expect(recorder?.directory.path == "/tmp/rec")
    }

    @Test func anEventLandsAsAnEnvelopeFileWithItsAttachments() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SentryRecorderTransport(directory: directory, lane: { $0() })
        let pathAttachment = directory.appending(path: "on-disk.txt")
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "recorded")
        let attachments = [
            Attachment(data: Data("blackbox".utf8), filename: "blackbox.txt", contentType: "text/plain"),
            Attachment(path: pathAttachment.path, filename: "on-disk.txt"),
            Attachment(path: directory.appending(path: "missing.txt").path, filename: "missing.txt"),
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("from disk".utf8).write(to: pathAttachment)

        try recorder.record(event, attachments: attachments)

        let id = event.eventId.sentryIdString
        let items = try Self.items(of: recorder.file(eventID: id))
        #expect(items.header["event_id"] as? String == id)
        #expect(items.entries.map { $0.header["type"] as? String } == ["event", "attachment", "attachment"])
        let payload = try #require(JSONSerialization.jsonObject(with: items.entries[0].payload) as? [String: Any])
        #expect(payload["event_id"] as? String == id)
        #expect(items.entries[1].header["filename"] as? String == "blackbox.txt")
        #expect(items.entries[1].header["content_type"] as? String == "text/plain")
        #expect(items.entries[1].header["attachment_type"] as? String == "event.attachment")
        #expect(items.entries[1].payload == Data("blackbox".utf8))
        #expect(items.entries[2].header["filename"] as? String == "on-disk.txt")
        #expect(items.entries[2].payload == Data("from disk".utf8))
    }

    @Test func theReporterRecordsInsteadOfSending() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SentryRecorderTransport(directory: directory, lane: { $0() })
        let options = CrashReporter(policy: Self.policy, recorder: recorder).options()
        #expect(!options.enableAutoSessionTracking, "session updates would reach Sentry past the recorder")
        #expect(!options.sendClientReports)
        #expect(options.beforeSendWithHint == nil)
        let send = try #require(options.beforeSend)
        let event = Event(level: .warning)

        #expect(send(event) == nil, "a recorded event is never sent")

        let items = try Self.items(of: recorder.file(eventID: event.eventId.sentryIdString))
        let payload = try #require(JSONSerialization.jsonObject(with: items.entries[0].payload) as? [String: Any])
        let tags = try #require(payload["tags"] as? [String: String])
        #expect(tags["app"] == CrashEventLabels.app, "the file holds the labeled event Sentry would receive")
    }

    @Test func withoutARecorderTheOptionsSendAsBefore() {
        let options = CrashReporter(policy: Self.policy, recorder: nil).options()
        #expect(options.beforeSend != nil)
        #expect(options.beforeSendWithHint == nil)
        #expect(options.enableAutoSessionTracking)
    }

    private static let policy = CrashReportingPolicy(
        bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
        telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sentry-recorder-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private struct Entry {
        let header: [String: Any]
        let payload: Data
    }

    /// Parses an envelope: the header line, then each item's header line and its `length` bytes.
    private static func items(of file: URL) throws -> (header: [String: Any], entries: [Entry]) {
        let data = try Data(contentsOf: file)
        var cursor = data.startIndex
        func headerLine() throws -> [String: Any] {
            let end = try #require(data[cursor...].firstIndex(of: 0x0A))
            let object = try #require(JSONSerialization.jsonObject(with: data[cursor..<end]) as? [String: Any])
            cursor = data.index(after: end)
            return object
        }
        let header = try headerLine()
        var entries: [Entry] = []
        while cursor < data.endIndex {
            let itemHeader = try headerLine()
            let length = try #require(itemHeader["length"] as? Int)
            let end = data.index(cursor, offsetBy: length)
            entries.append(Entry(header: itemHeader, payload: Data(data[cursor..<end])))
            cursor = data.index(after: end)
        }
        return (header, entries)
    }
}
#endif
