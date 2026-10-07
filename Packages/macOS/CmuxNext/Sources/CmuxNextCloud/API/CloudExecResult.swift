import Foundation

/// `POST /api/vm/{id}/exec`.
public struct CloudExecResult: Sendable, Hashable, Decodable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String

    enum CodingKeys: String, CodingKey { case exitCode, stdout, stderr }

    public init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? -1
        stdout = try c.decodeIfPresent(String.self, forKey: .stdout) ?? ""
        stderr = try c.decodeIfPresent(String.self, forKey: .stderr) ?? ""
    }
}
