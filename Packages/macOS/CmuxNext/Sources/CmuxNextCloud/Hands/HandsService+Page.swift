import CryptoKit
public import Foundation

/// Settings > Machines > Hands (cx-om025, webviews/src/pages/settings HandsGroup): the state the
/// page reads (`cmux.settings.hands.state`, live through `cmux.settings.hands.changed`) and its one
/// gesture (`cmux.settings.hands.run`). Values are JSON objects (`JSONSerialization`); the App
/// bridges them to the page's JSON.
///
/// A level change runs ``setLevel(hand:to:)`` or ``setDefault(profile:to:)``: a raise always goes
/// through the presence key (Touch ID, Face ID or the login password), never a check in the page.
/// The run answers when the change ended; a cancelled prompt is no error.
extension HandsService {
    public var pageState: [String: Any] {
        [
            "signed_in": isActive,
            "levels": [HandLevel.readOnly, .ask, .auto, .full].map(\.rawValue),
            "hands": hands.map { hand -> [String: Any] in
                ["hand": hand.hand, "name": hand.name.isEmpty ? hand.hand : hand.name, "profile": Self.pageNull(hand.profile?.rawValue),
                 "level": Self.pageNull(hand.level?.rawValue), "online": hand.online,
                 "pending": pending.values.filter { $0.hand == hand.hand }.count]
            },
            "defaults": Dictionary(uniqueKeysWithValues: defaults.map { ($0.key.rawValue, $0.value.rawValue) }),
            "secure_enclave": SecureEnclave.isAvailable,
            "prompt": Self.pageNull(prompt?.reason),
            "busy": Self.pageNull(busy),
            "error": Self.pageNull(pageError),
        ]
    }

    /// `{action: "refresh"}`, `{action: "level", hand, level}` or `{action: "default", profile, level}`.
    /// Answers `{}` or `{error}` (the same localized text as `pageState.error`).
    public func pageRun(_ params: [String: Any]) async -> [String: Any] {
        let level = (params["level"] as? String).flatMap(HandLevel.init(rawValue:))
        switch params["action"] as? String {
        case "refresh":
            await refresh()
            return [:]
        case "level":
            guard let hand = params["hand"] as? String, HandIDs.isHand(hand), let level else { return ["error": texts.failed] }
            return await change(hand, label: "level \(hand) \(level.rawValue)") { try await self.setLevel(hand: hand, to: level) }
        case "default":
            guard let profile = (params["profile"] as? String).flatMap(HandProfile.init(rawValue:)), let level else {
                return ["error": texts.failed]
            }
            return await change("default:\(profile.rawValue)", label: "default \(profile.rawValue) \(level.rawValue)") {
                try await self.setDefault(profile: profile, to: level)
            }
        default:
            return ["error": texts.failed]
        }
    }

    /// One level change at a time; the log line is the one `debug.hands` writes (`<label>: ok`).
    private func change(_ target: String, label: String, _ work: () async throws -> Void) async -> [String: Any] {
        guard busy == nil else { return ["error": texts.failed] }
        (busy, pageError) = (target, nil)
        defer { busy = nil }
        do {
            try await work()
            note("\(label): ok")
            return [:]
        } catch HandPresenceError.cancelled {
            note("\(label): failed cancelled")
            return [:]
        } catch {
            note("\(label): failed \(error)")
            let text = switch error {
            case let Failure.notLinked(text): text
            case HandPresenceError.unavailable: texts.unavailable
            default: texts.failed
            }
            pageError = text
            return ["error": text]
        }
    }

    private static func pageNull(_ value: Any?) -> Any { value ?? NSNull() }
}
