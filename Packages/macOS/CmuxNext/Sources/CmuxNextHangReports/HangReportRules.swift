import CCmuxLayoutReducerFFI
import Foundation
import os

/// The hang report rules, asked of Rust (cmux-tui/crates/cmux-hang-report, with their tests) over
/// the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `hang_report_*`): which frames may
/// be named, the leak scan, the report's allow-list, fitting and encoding, the stall histogram and
/// its samples, the daily cap, the outbox's age and order, the install id's rotation, the ask
/// policy, and the hardware and count buckets. Swift reads the facts (dyld, files, defaults,
/// sysctl, the clock as Unix seconds), asks here, and does what the answer says. Every op is pure.
nonisolated enum HangReportRules {
    /// One JSON call of the app FFI (`hang_report_<operation>`); nil when it does not answer (a
    /// pinned FFI without the op). A caller that gets nil sends nothing and names nothing.
    static func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        let name = "hang_report_" + operation
        guard let data = try? JSONEncoder().encode(request), let reply = callData(name, data),
              let decoded = try? JSONDecoder().decode(Reply.self, from: reply) else {
            log.fault("hang report rule \(name, privacy: .public) did not answer")
            return nil
        }
        return decoded
    }

    private static func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return Data(output.prefix(outputLength))
        }
        return nil
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "hang-reports")

    // MARK: Wire shapes

    /// A loaded image as the ops read it.
    struct Image: Encodable {
        var path: String
        var uuid: String
        var base: UInt64
        var size: UInt64

        init(_ image: LoadedImage) {
            path = image.path
            uuid = image.uuid
            base = image.base
            size = image.size
        }
    }

    /// One MetricKit delivery, its trees as JSON text.
    struct MetricKit: Encodable {
        struct Hang: Encodable {
            var durationMs: Int
            var callStackTree: String
        }

        struct CPUException: Encodable {
            var cpuMs: Int
            var sampledMs: Int
            var callStackTree: String
        }

        var hangs: [Hang]
        var cpuExceptions: [CPUException]
        var metrics: HangReport.Metrics
        var signposts: [MetricKitInput.Signpost]

        init(_ input: MetricKitInput) {
            hangs = input.hangs.map { Hang(durationMs: $0.durationMs, callStackTree: String(decoding: $0.callStackTree, as: UTF8.self)) }
            cpuExceptions = input.cpuExceptions.map {
                CPUException(cpuMs: $0.cpuMs, sampledMs: $0.sampledMs, callStackTree: String(decoding: $0.callStackTree, as: UTF8.self))
            }
            metrics = input.metrics
            signposts = input.signposts
        }
    }

    /// `hang_report_compose` and `hang_report_preview`'s request.
    struct Compose: Encodable {
        var context: HangReportBuilder.Context
        var watchdog: StallAggregate
        var metricKit: [MetricKit]
        var appBundlePath: String?
        var forbiddenTerms: [String]
        var systemImages: [String]
        var loadedImages: [Image]
    }

    /// `hang_report_compose`'s reply.
    struct Composed: Decodable {
        enum Status: String, Decodable {
            case empty
            case tooLarge
            case refused
            case ok
        }

        var status: Status
        var body: String?
        var readable: String?
        var findings: [PrivacyLeakScanner.Finding]
    }

    /// `hang_report_stack_refs`'s request and reply.
    struct Trees: Encodable { var trees: [String] }
    struct StackRefs: Decodable {
        var names: [String] = []
        var uuids: [String] = []
    }

    /// `hang_report_frames`'s request and reply.
    struct Frames: Encodable {
        struct Address: Encodable {
            var address: UInt64
            var image: Image?
        }

        var addresses: [Address]
        var appBundlePath: String?
        var forbiddenTerms: [String]
    }
    struct FramesReply: Decodable { var frames: [HangReportFrame] }

    /// Replies of one field.
    struct Readable: Decodable { var readable: String? }
    struct Findings: Decodable { var findings: [PrivacyLeakScanner.Finding] }
    struct Sendable: Decodable { var sendable: Bool }
    struct Aggregate: Codable { var aggregate: StallAggregate }
    struct Due: Decodable { var due: Bool }
    struct Day: Decodable { var day: String }
    struct Keep: Decodable { var keep: Bool }
    struct Now: Encodable { var now: Double }

    /// `hang_report_note_stall` and `hang_report_note_hang`'s reply.
    struct Noted: Decodable {
        var bucket: Int?
        var sample: HangSample?
    }
}
