import Foundation

/// Detects runtime diagnostics that identify sidebar view-update reentrancy.
public struct SidebarRuntimeFaultScanner: Sendable {
    /// A matched runtime diagnostic and the line that contained it.
    public struct Fault: Equatable, Sendable {
        /// The stable diagnostic fragment used for matching.
        public let signature: String

        /// The complete log line containing ``signature``.
        public let line: String

        /// Creates a matched runtime diagnostic.
        ///
        /// - Parameters:
        ///   - signature: The stable diagnostic fragment used for matching.
        ///   - line: The complete log line containing the fragment.
        public init(signature: String, line: String) {
            self.signature = signature
            self.line = line
        }
    }

    /// Runtime messages emitted by SwiftUI and AppKit for the issue 8004 topology.
    public static let signatures = [
        "Publishing changes from within view updates is not allowed",
        "Modifying state during view update, this will cause undefined behavior",
        "NSHostingView is being laid out reentrantly while rendering its SwiftUI content",
    ]

    /// Creates the issue 8004 runtime-fault scanner.
    public init() {}

    /// Returns every matching diagnostic line in source order.
    ///
    /// - Parameter text: Unified-log or standard-error text to inspect.
    /// - Returns: Each matching signature paired with its complete source line.
    public func faults(in text: String) -> [Fault] {
        text.split(whereSeparator: \.isNewline).flatMap { rawLine in
            let line = String(rawLine)
            return Self.signatures.compactMap { signature in
                line.localizedStandardContains(signature)
                    ? Fault(signature: signature, line: line)
                    : nil
            }
        }
    }
}
