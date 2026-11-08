import Foundation

struct RecordingCommandInvocation: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval?
}
