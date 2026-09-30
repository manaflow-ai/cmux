import CmuxAuthRuntime
import Foundation

extension VMClient {
    /// Executes a command on a VM while preserving the caller's optional account and team scope.
    ///
    /// - Parameters:
    ///   - id: The VM identifier.
    ///   - command: The command to execute on the VM.
    ///   - timeoutMs: The guest execution deadline in milliseconds.
    ///   - expectedTeamScope: Captured authorization scope that must remain current throughout the request.
    /// - Returns: The command's exit code, standard output, and standard error.
    /// - Throws: An authorization, transport, or response error if execution cannot complete.
    public func exec(id: String, command: String, timeoutMs: Int = 30_000, expectedTeamScope: AuthenticatedTeamScope? = nil) async throws -> VMExecResult {
        return try await withOperation(.exec, foreground: true) {
            let body: [String: Any] = ["command": command, "timeoutMs": timeoutMs]
            let encodedID = try pathSegment(id, fieldName: "vm id")
            let (data, http) = try await request(
                "POST",
                path: "/api/vm/\(encodedID)/exec",
                jsonBody: body,
                timeoutSeconds: max(1, Double(timeoutMs) / 1000.0 + 5.0), expectedTeamScope: expectedTeamScope
            )
            try ensureOK(http, data: data)
            let obj = try decodeJSONObject(data)
            let exitCode = (obj["exitCode"] as? Int) ?? ((obj["exitCode"] as? Double).map(Int.init) ?? -1)
            let stdout = (obj["stdout"] as? String) ?? ""
            let stderr = (obj["stderr"] as? String) ?? ""
            return VMExecResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
        }
    }
}
