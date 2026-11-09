public import CmuxNextDaemon
public import Foundation

/// One stdin-JSON call of the bundled `cmux` (`cmux cloud <subcommand>`, cmux-tui `cli/cloud_*.rs`):
/// the request goes on the child's stdin (a credential never goes in argv), the answer is its last
/// stdout line. Cloud logic lives in that Rust; Swift only runs it. Every one-shot Cloud subcommand
/// the app runs goes through this one runner.
public struct CloudCLICall: Sendable {
    /// The app's bundled `cmux` (or `CMUX_NEXT_TUI_BIN`).
    public let cli: BundledExecutable

    public init(cli: BundledExecutable) { self.cli = cli }

    /// Why a call gave no answer line: no `cmux` in this build, or a child that failed, timed out or printed none.
    public struct NoAnswer: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    /// Runs `cmux <arguments>` with `stdin`; the last non-empty stdout line.
    public func run(_ arguments: [String], stdin: Data, timeout: Duration) async throws -> Data {
        guard let binary = await cli.resolve() else { throw NoAnswer(description: "this build has no cmux") }
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, stdin: stdin,
                                                 timeout: timeout, clock: ContinuousClock())
        guard let line = result.stdout.split(separator: UInt8(ascii: "\n")).last(where: { !$0.isEmpty }) else {
            throw NoAnswer(description: "cmux \(arguments.joined(separator: " ")) answered nothing (exit \(result.status))")
        }
        return Data(line)
    }

    /// `cmux cloud automation-relay` as the signed-in person of `auth`: what `cmux automation
    /// --target cloud`, the Automations page and the Chief's automation tool call (the app's
    /// `cloud.automation`). The forward takes `{op, params?, idempotency_key?}` as JSON bytes and
    /// answers `{ok: true, value}` or `{ok: false, error: {code, message, details?}}`; the rules are
    /// cmux-tui's `cmux_cloud_wire::automation`. The token is read per call, never stored.
    @MainActor
    public func automationRelay(signedIn auth: CloudAuth) -> @Sendable (Data) async -> Data {
        let api = auth.configuration.ownerAPIBaseURL().absoluteString
        let token: @Sendable () async -> Result<String?, any Error> = { @MainActor [weak auth] in
            guard let auth, auth.isSignedIn else { return .success(nil) }
            do { return .success(try await auth.tokens().access) } catch { return .failure(error) }
        }
        return { [self] request in
            let credential: String?
            switch await token() {
            case let .success(found): credential = found
            case let .failure(error): return Self.unreachable(String(describing: error))
            }
            // The request is parsed and re-encoded inside the envelope, so its bytes can never add a field of their own.
            let parsed = (try? JSONSerialization.jsonObject(with: request, options: .fragmentsAllowed)) ?? NSNull()
            let envelope: [String: Any] = ["api": api, "credential": credential.map { $0 as Any } ?? NSNull(), "request": parsed]
            guard let stdin = try? JSONSerialization.data(withJSONObject: envelope) else { return Self.unreachable("the request is not JSON") }
            do {
                return try await run(["cloud", "automation-relay"], stdin: stdin, timeout: .seconds(25))
            } catch {
                return Self.unreachable(String(describing: error))
            }
        }
    }

    private static func unreachable(_ message: String) -> Data {
        let answer: [String: Any] = ["ok": false, "error": ["code": "owner.unreachable", "message": message]]
        return (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"ok":false,"error":{"code":"owner.unreachable","message":""}}"#.utf8)
    }
}
