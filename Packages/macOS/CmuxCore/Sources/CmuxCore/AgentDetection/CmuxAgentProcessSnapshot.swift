internal import Foundation

/// An immutable process identity snapshot supplied to the detection engine.
public struct CmuxAgentProcessSnapshot: Equatable, Hashable, Sendable {
    /// The process name reported by the operating system.
    public let processName: String
    /// The resolved executable path, when the caller can obtain it.
    public let processPath: String?
    /// The process argument vector captured at the same observation point.
    public let arguments: [String]
    /// The process environment captured at the same observation point.
    public let environment: [String: String]

    /// Creates a process snapshot from immutable identity fields.
    public init(
        processName: String,
        processPath: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.processName = processName
        self.processPath = processPath
        self.arguments = arguments
        self.environment = environment
    }

    /// Returns distinct executable basenames available to process matchers.
    public var executableBasenames: [String] {
        var values: [String] = []
        if !processName.isEmpty {
            values.append((processName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
        }
        if let processPath, !processPath.isEmpty {
            values.append((processPath.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
        }
        if let first = arguments.first, !first.isEmpty {
            values.append((first.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
