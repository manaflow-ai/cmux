import CmuxMobileWire

/// Calls into the session host with the refusal mapping of c13-viewers.md
/// section 3: `git.not_a_repo` passes through, everything else is
/// `git.failed`, and a reply that does not decode is a failure too.
struct GitReads {
    static func status(path: String, reader: any MobileGitReader) async throws -> GitStatusResult {
        try decode(await call("git.status", params: .object(["path": .string(path)]), reader: reader), as: GitStatusResult.self)
    }

    static func diff(_ params: GitDiffParams, reader: any MobileGitReader) async throws -> GitDiffResult {
        let encoded = try JSONValue(encoding: params)
        return try decode(await call("git.diff", params: encoded, reader: reader), as: GitDiffResult.self)
    }

    private static func call(_ operation: String, params: JSONValue, reader: any MobileGitReader) async throws -> JSONValue {
        do {
            return try await reader.read(operation, params: params)
        } catch let error as MobileDaemonError where error.code == MobileDaemonError.gitNotARepoCode {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MobileDaemonError.gitFailed()
        }
    }

    private static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        do {
            return try value.decode(as: type)
        } catch {
            throw MobileDaemonError.gitFailed("the session host answered an unexpected shape")
        }
    }
}
