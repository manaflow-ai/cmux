import CmuxNextCompat
import Foundation

extension CEFTracing {
    /// A recording's trace and meta.json, touched only on the files lane.
    nonisolated struct Files: Sendable {
        /// The bytes read at each end of a trace by ``check(_:)``.
        static let edgeBytes = 256

        let directory: String
        let trace: String
        let meta: String

        /// What Chromium left at the path it reported.
        nonisolated enum Check: Sendable, Equatable {
            case complete
            /// No file, or an empty one.
            case missing
            /// Not a whole JSON trace.
            case truncated
        }

        /// Makes the directory and removes an earlier recording's trace and meta.json there.
        ///
        /// - Throws: The directory could not be made or an old file removed.
        func prepare() throws {
            let files = FileManager.checked
            try files.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for path in [trace, meta] where files.fileExists(atPath: path) {
                try files.removeItem(atPath: path)
            }
        }

        /// Whether `path` holds a whole JSON trace, as Chromium's file endpoint writes one: `{"traceEvents":` first
        /// and the object's closing brace last (content/browser/tracing/tracing_controller_impl_data_endpoint.cc).
        /// Only the two ends are read: a trace can be hundreds of MB, and a cut one has lost its closing brace.
        static func check(_ path: String) -> Check {
            let attributes = try? FileManager.checked.attributesOfItem(atPath: path)
            guard let size = (attributes?[.size] as? NSNumber)?.uint64Value, size > 0,
                  let handle = try? FileHandle.blockingForReading(from: URL(fileURLWithPath: path)) else { return .missing }
            defer { try? handle.close() }
            let window = min(size, UInt64(edgeBytes))
            guard let head = try? handle.blockingRead(upToCount: Int(window)),
                  (try? handle.seek(toOffset: size - window)) != nil,
                  let tail = try? handle.blockingRead(upToCount: Int(window)) else { return .truncated }
            return isWholeTrace(head: head, tail: tail) ? .complete : .truncated
        }

        /// A JSON trace object's first and last bytes: `{` then the `traceEvents` key, and a closing `}`.
        static func isWholeTrace(head: Data, tail: Data) -> Bool {
            let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
            guard head.first(where: { !space.contains($0) }) == UInt8(ascii: "{"),
                  tail.last(where: { !space.contains($0) }) == UInt8(ascii: "}") else { return false }
            return head.range(of: Data(#""traceEvents""#.utf8)) != nil
        }
    }
}
