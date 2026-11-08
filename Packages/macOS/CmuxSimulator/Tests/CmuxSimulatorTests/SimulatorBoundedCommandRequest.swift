import Foundation

struct SimulatorBoundedCommandRequest: Sendable, Equatable {
    let directory: String
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval?
    let standardOutputLimit: Int
    let standardErrorLimit: Int
}
