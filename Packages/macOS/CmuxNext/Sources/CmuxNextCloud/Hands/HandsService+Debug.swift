import CryptoKit
public import Foundation

/// `debug.hands` (the App's control socket, debug builds and proofs): the service's state as JSON
/// text, after one optional action.
///
/// - `{"action": "refresh"}` reads the hands and their waiting requests.
/// - `{"action": "enroll"}` makes and registers the presence key.
/// - `{"action": "level", "hand": <id>, "level": <level>}` and
///   `{"action": "default", "profile": <profile>, "level": <level>}` start a level change and answer
///   at once (a raise waits for the presence prompt; `prompt` shows its reason, `log` the result).
/// - `{"action": "cancel_prompt"}` cancels the presence prompt that asks now.
/// - `{"action": "raise_unsigned", "hand": <id>, "level": <level>}` sends a raise signed by the
///   install key, not the presence key; `result` is the server's answer (it must refuse).
///
/// Waiting requests are answered through `debug.notifications` (`allow`/`deny` with the banner id),
/// the banner's own path.
extension HandsService {
    public func debug(_ params: [String: String]) async -> String {
        var result: String?
        let level = params["level"].flatMap(HandLevel.init(rawValue:))
        switch params["action"] {
        case "refresh":
            await refresh()
        case "enroll":
            result = await outcome { try await self.enrollPresence() }
        case "level":
            if let hand = params["hand"], let level { start("level \(hand) \(level.rawValue)") { try await self.setLevel(hand: hand, to: level) } }
        case "default":
            if let profile = params["profile"].flatMap(HandProfile.init(rawValue:)), let level {
                start("default \(profile.rawValue) \(level.rawValue)") { try await self.setDefault(profile: profile, to: level) }
            }
        case "cancel_prompt":
            prompt?.cancel()
        case "raise_unsigned":
            if let hand = params["hand"], let level { result = await outcome { try await self.raiseWithoutPresence(hand: hand, to: level) } }
        default:
            break
        }
        let report: [String: Any] = [
            "hands": hands.map { ["hand": $0.hand, "name": $0.name, "profile": Self.orNull($0.profile?.rawValue),
                                  "level": Self.orNull($0.level?.rawValue), "online": $0.online, "pending": Self.orNull($0.pendingApprovals)] as [String: Any] },
            "pending": pending.values.sorted { $0.at < $1.at }.map { ["key": $0.key, "hand": $0.hand, "id": $0.id, "summary": $0.summary] as [String: Any] },
            "prompt": Self.orNull(prompt?.reason),
            "secure_enclave": SecureEnclave.isAvailable,
            "result": Self.orNull(result),
            "log": log,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    /// Runs `work` without waiting for it; the log records how it ended.
    private func start(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        // task-owner: HandsService.debug: one proof-driven level change; it ends with its prompt or request.
        Task { @MainActor [weak self] in
            let ended = await Self.describe { try await work() }
            self?.note("\(label): \(ended)")
        }
    }

    private func outcome<T>(_ work: @MainActor () async throws -> T) async -> String {
        await Self.describe { _ = try await work() }
    }

    private static func describe(_ work: @MainActor () async throws -> Void) async -> String {
        do {
            try await work()
            return "ok"
        } catch CloudAPIError.http(let status, let code, let message, _, _) {
            return "refused \(status) \(code ?? "") \(message ?? "")"
        } catch {
            return "failed \(error)"
        }
    }
}
