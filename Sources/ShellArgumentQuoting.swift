import Foundation

enum ShellArgumentQuoting {
    static func singleQuoted(_ value: String) -> String {
        let escapedValue = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escapedValue)'"
    }
}
