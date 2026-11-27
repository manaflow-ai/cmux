import Foundation

/// Parses machine receipts without depending on localized app resources.
public struct CloudMachineCreateOutput: Sendable {
    private let legacyCreatedFormat: String

    /// Supports the bundled protocol and an optional older CLI display format.
    /// - Parameter legacyCreatedFormat: Localized format containing one `%@` machine placeholder.
    public init(legacyCreatedFormat: String) {
        self.legacyCreatedFormat = legacyCreatedFormat
    }

    /// Reads a complete transcript, prioritizing the protocol receipt over display text.
    /// - Parameter output: Complete lines, or a final process transcript.
    /// - Returns: The first valid machine identifier, if one was announced.
    public func machineID(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where line.hasPrefix("OK ") {
            for token in line.split(whereSeparator: \.isWhitespace) where token.hasPrefix("machine=") {
                let id = String(token.dropFirst("machine=".count))
                if valid(id) { return id }
            }
        }
        let parts = legacyCreatedFormat.components(separatedBy: "%@")
        guard parts.count == 2 else { return nil }
        for line in lines where line.hasPrefix(parts[0]) && line.hasSuffix(parts[1]) {
            guard line.count > parts[0].count + parts[1].count else { continue }
            let id = String(line.dropFirst(parts[0].count).dropLast(parts[1].count)).trimmingCharacters(in: .whitespaces)
            if valid(id) { return id }
        }
        return nil
    }

    /// Removes progress receipts before the app redacts and localizes an error.
    /// - Parameter output: Complete process transcript.
    /// - Returns: Error text without machine receipts or success markers.
    public func failureText(in output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("OK ") && machineID(in: line) == nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses only terminated lines; a split identifier must never trigger partial cleanup.
    func consume(_ chunk: String, carry: inout String) -> String? {
        let input = carry + chunk
        guard let lastNewline = input.lastIndex(where: \.isNewline) else {
            carry = String(input.suffix(512))
            return nil
        }
        let machineID = machineID(in: String(input[...lastNewline]))
        carry = String(input[input.index(after: lastNewline)...].suffix(512))
        return machineID
    }

    private func valid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}
