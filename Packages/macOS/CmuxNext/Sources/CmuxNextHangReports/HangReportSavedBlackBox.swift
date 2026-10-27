import CmuxNextTrace
import Foundation

/// The black box a quit saves beside the watchdog aggregate (``HangReportService/saveForNextLaunch()``), so the
/// next launch's report, which usually carries the hang, carries its black box too. Only the records the upload
/// decoder keeps are written (``TraceBlackBoxUpload``: catalog names and numbers, no key-timing, per-key PTY or
/// flow record), so the file holds nothing a report could not send.
struct HangReportSavedBlackBox: Codable, Sendable, Equatable {
    /// One kept record.
    struct Event: Codable, Sendable, Equatable {
        var process: UInt16
        var timestamp: UInt64
        var name: String
        var categoryBit: UInt8
        var phaseCode: UInt8
        var flags: UInt8
        var arg0: UInt64
        var arg1: UInt64
    }

    var events: [Event]

    /// The records of `records` the upload decoder keeps, oldest first.
    init(_ records: [TraceBlackBoxUpload.Record]) {
        events = TraceBlackBoxUpload().events(records).compactMap { record in
            guard let name = record.name else { return nil }
            return Event(process: record.process.rawValue, timestamp: record.timestamp, name: name.text,
                         categoryBit: name.categoryBit, phaseCode: record.phaseCode, flags: record.flags,
                         arg0: record.arg0, arg1: record.arg1)
        }
    }

    /// The saved records (each a catalog name: only those were kept); a role this build does not know is left out.
    var records: [TraceBlackBoxUpload.Record] {
        events.compactMap { event in
            guard let process = TraceRuntime.Role(rawValue: event.process) else { return nil }
            return TraceBlackBoxUpload.Record(
                process: process, timestamp: event.timestamp,
                name: TraceBlackBoxUpload.Record.Name(text: event.name, kind: .catalog, categoryBit: event.categoryBit),
                phaseCode: event.phaseCode, flags: event.flags, arg0: event.arg0, arg1: event.arg1)
        }
    }
}
