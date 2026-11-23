import Foundation

/// A machine command's result, as cmux-cloud-machine `models::read("exec_result")` answers it
/// (a missing exit code is -1, missing output empty).
public struct CloudExecResult: Sendable, Hashable, Codable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
