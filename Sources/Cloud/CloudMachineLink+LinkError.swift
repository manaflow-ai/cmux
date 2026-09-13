import Foundation

extension CloudMachineLink {
    enum LinkError: Error, LocalizedError {
        case clientMissing
        case spawnFailed(String)
        case exited(status: Int32, output: String)
        case timedOut
        case inputTooLarge

        var errorDescription: String? {
            switch self {
            case .inputTooLarge:
                return String(localized: "cloud.link.inputTooLarge", defaultValue: "The machine input chunk is too large. Split it into smaller chunks and retry.")
            case .clientMissing:
                return "No cmux-tui client is bundled with this build (Contents/Resources/bin/cmux-tui) and CMUX_TUI_CLIENT is unset."
            case .spawnFailed(let detail):
                return "cmux-tui could not be started: \(detail)"
            case .exited(let status, let output):
                let tail = output.split(separator: "\n").suffix(3).joined(separator: " · ")
                return "cmux-tui link exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail)")
            case .timedOut:
                return "cmux-tui link did not report a socket within the connect timeout."
            }
        }
    }

}
