import Foundation

/// One queued agent hook event captured by the shell producer.
///
/// The shell producer writes the record without starting the cmux CLI. The
/// session forwarder later decodes it and admits it to the app's ordered hook
/// queue exactly as `cmux hooks enqueue <agent> <subcommand>` would have.
///
/// The byte format is:
///
/// ```text
/// cmux-agent-hook-v1\n
/// <agent>\n
/// <subcommand>\n
/// KEY=VALUE\0 ... \0   (environment entries, terminated by an empty entry)
/// <payload bytes to end of file>
/// ```
public struct AgentHookSpoolRecord: Sendable, Equatable {
    /// The first line of every record; a different line rejects the record.
    public static let formatMarker = "cmux-agent-hook-v1"

    /// The agent name, such as `claude`.
    public let agent: String
    /// The queued hook subcommand, such as `pre-tool-use`.
    public let subcommand: String
    /// The hook process environment values the producer captured.
    public let environment: [String: String]
    /// The hook's original stdin bytes.
    public let payload: Data

    /// Creates a record value.
    ///
    /// - Parameters:
    ///   - agent: The agent name.
    ///   - subcommand: The queued hook subcommand.
    ///   - environment: Captured hook environment values.
    ///   - payload: The hook's stdin bytes.
    public init(agent: String, subcommand: String, environment: [String: String], payload: Data) {
        self.agent = agent
        self.subcommand = subcommand
        self.environment = environment
        self.payload = payload
    }

    /// Decodes a record written by the shell producer.
    ///
    /// - Parameter data: The complete file contents.
    /// - Returns: `nil` when the marker, header lines, or environment block are malformed.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        func line() -> String? {
            guard let end = bytes[index...].firstIndex(of: 0x0A) else { return nil }
            defer { index = end + 1 }
            return String(bytes: bytes[index..<end], encoding: .utf8)
        }
        guard line() == Self.formatMarker,
              let agent = line(), Self.isSafeToken(agent),
              let subcommand = line(), Self.isSafeToken(subcommand) else {
            return nil
        }
        var environment: [String: String] = [:]
        while true {
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            if end == index { break }
            guard let entry = String(bytes: bytes[index..<end], encoding: .utf8),
                  let separator = entry.firstIndex(of: "=") else {
                return nil
            }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        self.init(
            agent: agent,
            subcommand: subcommand,
            environment: environment,
            payload: Data(bytes[index...])
        )
    }

    /// Encodes the record in the shell producer's format.
    ///
    /// - Returns: Bytes that ``init(data:)`` decodes to an equal record.
    public func encoded() -> Data {
        var data = Data("\(Self.formatMarker)\n\(agent)\n\(subcommand)\n".utf8)
        for key in environment.keys.sorted() {
            data.append(Data("\(key)=\(environment[key] ?? "")".utf8))
            data.append(0)
        }
        data.append(0)
        data.append(payload)
        return data
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}
