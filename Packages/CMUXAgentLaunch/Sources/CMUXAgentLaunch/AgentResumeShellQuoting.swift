import Foundation

struct AgentResumeShellQuoting: Sendable, Equatable {
    func singleQuoted(_ value: String) -> String {
        if value.utf8.contains(where: { $0 >= 0x80 }) {
            return asciiPrintfCommandSubstitution(for: value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func asciiPrintfCommandSubstitution(for value: String) -> String {
        let octalBytes = value.utf8
            .map { String(format: #"\%03o"#, Int($0)) }
            .joined()
        return #""$(printf '"# + octalBytes + #"')""#
    }
}
