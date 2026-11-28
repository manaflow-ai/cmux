import CmuxNextDaemon
import Foundation

/// Settings > Environment (RFD 0222 (c)1, hq#37585): the person's vault through the local daemon's
/// `vault-env` op. This only adds the platform origin and install bearer (``VaultEnvRequest``) and
/// shapes answers for the page; Rust owns the platform calls, the value encoding and every check.
/// It speaks JSON `Data` so ``SettingsPageProvider`` needs no daemon types.
///
/// A secret value passes through `run` once, on its way to the daemon, and is never kept, logged or
/// answered back: `list` names entries, it never returns a value.
@MainActor
final class SettingsVault {
    /// One `vault-env` action on the local daemon with the signed-in install token.
    typealias Send = @MainActor (_ action: String, _ params: JSONValue) async throws -> JSONValue

    /// The page's writes; `list` and `grants` are what `state` reads.
    static let writes: Set<String> = ["set", "policy", "rm"]

    private let available: @MainActor () -> Bool
    private let send: Send

    init(available: @escaping @MainActor () -> Bool, send: @escaping Send) {
        self.available = available
        self.send = send
    }

    /// `cmux.settings.vault.state`: `{available, unsupported, entries, grants, error?, code?}`.
    /// Unavailable (Cloud off or signed out) and unsupported (a daemon without `vault-env-v1`) answer
    /// no lists, so the card explains instead.
    func state() async -> Data {
        guard available() else { return Self.encode(["available": .bool(false), "unsupported": .bool(false), "entries": .array([]), "grants": .array([])]) }
        do {
            let entries = try await send("list", .object([:]))["entries"] ?? .array([])
            // Grants are a second read: a failed one still shows the entries.
            var answer: [String: JSONValue] = ["available": .bool(true), "unsupported": .bool(false), "entries": entries, "grants": .array([])]
            do { answer["grants"] = try await send("grants", .object([:]))["grants"] ?? .array([]) }
            catch { answer.merge(Self.failure(error)) { $1 } }
            return Self.encode(answer)
        } catch DaemonError.missingCapabilities {
            return Self.encode(["available": .bool(true), "unsupported": .bool(true), "entries": .array([]), "grants": .array([])])
        } catch {
            var answer: [String: JSONValue] = ["available": .bool(true), "unsupported": .bool(false), "entries": .array([]), "grants": .array([])]
            answer.merge(Self.failure(error)) { $1 } // the error row and Retry
            return Self.encode(answer)
        }
    }

    /// `cmux.settings.vault.run` `{action, params}`: `{result}` or `{error, code}` (`vault.key_shaped_variable`, ...).
    func run(_ request: Data) async -> Data {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: request),
              let action = body["action"]?.stringValue, Self.writes.contains(action) else {
            return Self.encode(["error": .string("unknown vault action"), "code": .string("vault.invalid")])
        }
        guard available() else { return Self.encode(["error": .string("cloud_disabled"), "code": .string("cloud_disabled")]) }
        do {
            return Self.encode(["result": try await send(action, body["params"] ?? .object([:]))])
        } catch {
            return Self.encode(Self.failure(error))
        }
    }

    /// The daemon's refusal message and `error_code`; any other failure names no detail (it could quote a request).
    private static func failure(_ error: any Error) -> [String: JSONValue] {
        switch error {
        case DaemonError.command(_, let message, let code, _, _):
            return ["error": .string(message), "code": .string(code ?? "vault.failed")]
        case DaemonError.missingCapabilities:
            return ["error": .string("vault.unsupported"), "code": .string("vault.unsupported")]
        default:
            return ["error": .string("vault.unavailable"), "code": .string("vault.unavailable")]
        }
    }

    private static func encode(_ object: [String: JSONValue]) -> Data {
        (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
    }
}
