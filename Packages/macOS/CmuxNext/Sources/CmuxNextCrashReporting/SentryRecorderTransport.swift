#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
public import Foundation
import os
public import Sentry

/// Writes each Sentry event of this launch as one envelope file instead of sending it.
/// DEBUG and bench builds only: Release compiles none of it.
///
/// `CMUX_NEXT_SENTRY_RECORDER=<dir>` turns it on (``init(environment:)``); ``CrashReporter`` then installs it
/// on its options. Events still pass the scrubber and the cmux-next labels first, so a file holds exactly
/// what Sentry would have received, and nothing leaves the machine: every event is dropped after it is
/// recorded, and session updates and client reports are off. Crash events of the previous run go through
/// the same callback at relaunch, so a crash lands as a file too (crash-matrix.py `--recorder DIR`).
///
/// The file is `<event_id>.envelope` in Sentry's envelope format
/// (https://develop.sentry.dev/sdk/data-model/envelopes/): the header `{"event_id":...}`, the `event` item,
/// then one `attachment` item per attachment ``record(_:attachments:)`` is given. It is written atomically
/// on the recorder's lane, never on the thread that captured the event.
///
/// Recording starts only when Sentry starts (``CrashReportingPolicy``): a DEV build also needs
/// `CMUX_NEXT_DEV_SENTRY=1`.
public final class SentryRecorderTransport: Sendable {
    /// Runs one block off the caller's thread, in order.
    public typealias Lane = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Why an event was not recorded.
    public enum RecordError: Error, Equatable {
        /// The event's serialized form is not a JSON object.
        case eventNotJSON
    }

    /// The variable that names the directory. A `CMUX_NEXT_` name, because the app strips other inherited
    /// `CMUX` variables at launch (LaunchIdentity.stripInheritedEnvironment).
    public static let environmentKey = "CMUX_NEXT_SENTRY_RECORDER"
    /// The extension of every recorded file.
    public static let fileExtension = "envelope"

    /// Where the envelopes go; created on the first write.
    public let directory: URL
    private let lane: Lane
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    /// The recorder `environment` asks for: nil without ``environmentKey`` or with an empty value.
    /// Writes on its own utility queue.
    public convenience init?(environment: [String: String]) {
        guard let path = environment[Self.environmentKey], !path.isEmpty else { return nil }
        let queue = DispatchQueue(label: "com.cmuxterm.app.next.sentry-recorder", qos: .utility)
        self.init(directory: URL(fileURLWithPath: path, isDirectory: true), lane: { queue.async(execute: $0) })
    }

    /// Test seam: the directory and the lane the writes run on.
    public init(directory: URL, lane: @escaping Lane) {
        self.directory = directory
        self.lane = lane
    }

    /// The file an event with `eventID` is recorded in.
    public func file(eventID: String) -> URL {
        directory.appending(path: "\(eventID).\(Self.fileExtension)", directoryHint: .notDirectory)
    }

    /// Makes `options` record every event instead of sending it. `prepare` is what the options' own
    /// `beforeSend` does (scrub and label); it runs first, so the file holds what Sentry would receive.
    /// Only the event is recorded: sentry-cocoa 9 shows an event's attachments only to the deprecated
    /// `beforeSendWithHint`, and its next major version passes them to `beforeSend`.
    public func install(on options: Options, prepare: @escaping (Event) -> Event) {
        options.beforeSend = { [self] event in
            recordOrLog(prepare(event), attachments: [])
            return nil
        }
        stopSessionsAndReports(on: options)
    }

    /// The hint form of ``install(on:prepare:)``, for options whose own hook is `beforeSendWithHint`
    /// (sentry-cocoa 9 then never calls `beforeSend`, so the plain form would record nothing). `prepare` is
    /// that hook's work (the previous run's crash evidence, scrub and label); the event is recorded with the
    /// attachments the hint holds after it, as Sentry would have sent them.
    public func install(on options: Options, prepareWithHint prepare: @escaping (Event, Hint) -> Event) {
        options.beforeSendWithHint = { [self] event, hint in
            recordOrLog(prepare(event, hint), attachments: hint.attachments)
            return nil
        }
        stopSessionsAndReports(on: options)
    }

    private func recordOrLog(_ prepared: Event, attachments: [Attachment]) {
        do {
            try record(prepared, attachments: attachments)
        } catch {
            let id = prepared.eventId.sentryIdString
            logger.error("sentry recorder: event \(id, privacy: .public) not recorded: \(String(describing: error), privacy: .public)")
        }
    }

    /// Session updates and client reports would reach Sentry past the recorder.
    private func stopSessionsAndReports(on options: Options) {
        options.enableAutoSessionTracking = false
        options.sendClientReports = false
    }

    /// Serializes `event` and copies the attachments' data on the caller's thread, then writes
    /// ``file(eventID:)`` on the lane. An attachment whose file cannot be read is left out, as Sentry does.
    public func record(_ event: Event, attachments: [Attachment] = []) throws(RecordError) {
        let object = event.serialize()
        guard JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object) else { throw .eventNotJSON }
        let eventID = event.eventId.sentryIdString
        let parts = attachments.compactMap(Part.init)
        let target = file(eventID: eventID)
        let directory = directory
        let logger = logger
        lane {
            let envelope = Self.envelope(eventID: eventID, eventJSON: json, parts: parts)
            do {
                try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
                try envelope.blockingWrite(to: target, options: .atomic)
            } catch {
                let name = target.lastPathComponent
                logger.error("sentry recorder: \(name, privacy: .public) not written: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// One attachment, copied off the SDK's object.
    struct Part: Sendable {
        enum Body: Sendable {
            case data(Data)
            case file(String)
        }

        let filename: String
        let contentType: String?
        /// Sentry's `attachment_type` name.
        let attachmentType: String
        let body: Body

        init?(_ attachment: Attachment) {
            if let data = attachment.data {
                body = .data(data)
            } else if let path = attachment.path {
                body = .file(path)
            } else {
                return nil
            }
            filename = attachment.filename
            contentType = attachment.contentType
            attachmentType = attachment.attachmentType == .viewHierarchy ? "event.view_hierarchy" : "event.attachment"
        }

        /// The bytes, read from disk for a path attachment; nil when that file cannot be read.
        func bytes() -> Data? {
            switch body {
            case .data(let data): data
            case .file(let path): FileManager.checked.contents(atPath: path)
            }
        }
    }

    /// The envelope: its header, the event item, then each readable attachment's item.
    static func envelope(eventID: String, eventJSON: Data, parts: [Part]) -> Data {
        var envelope = Data()
        func line(_ header: [String: Any], _ payload: Data?) {
            // Only strings and integers: always valid JSON.
            envelope.append((try? JSONSerialization.data(withJSONObject: header, options: .sortedKeys)) ?? Data("{}".utf8))
            envelope.append(0x0A)
            guard let payload else { return }
            envelope.append(payload)
            envelope.append(0x0A)
        }
        line(["event_id": eventID], nil)
        line(["type": "event", "length": eventJSON.count], eventJSON)
        for part in parts {
            guard let bytes = part.bytes() else { continue }
            var header: [String: Any] = ["type": "attachment", "length": bytes.count, "filename": part.filename,
                                         "attachment_type": part.attachmentType]
            if let contentType = part.contentType { header["content_type"] = contentType }
            line(header, bytes)
        }
        return envelope
    }
}
#endif
