import Foundation

struct VMExecResult: Sendable {
    let exitCode: Int
    let stdout: String
    let stderr: String
}
