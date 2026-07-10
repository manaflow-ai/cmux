import Foundation

struct RecordingCommandInvocation: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval?
}
