import CmuxNextHomeEngine
import Foundation

/// The user's two cloud Chiefs in Home (Lawrence 2026-10-19): the Hosted
/// Chief (no `brain_place`; the Cloud brain answers, so Home works while the
/// user's Macs are off) is the default, and a Chief placed on a paired server
/// stays as "Chief (Mac mini)", one tap away.
nonisolated struct HomeCloudChiefs: Sendable, Equatable {
    var hosted: CloudChief?
    var placed: CloudChief?

    /// Which of the two the Chief tab shows: the placed one only when the
    /// user picked it and it exists; else the hosted one, else the placed one.
    func shown(choice: HomeChiefChoice) -> CloudChief? {
        if choice == .placed, let placed { return placed }
        return hosted ?? placed
    }

    /// The cloud Chief whose main conversation is `conversation`.
    func chief(for conversation: String) -> CloudChief? {
        [hosted, placed].compactMap { $0 }.first { $0.mainConversation == conversation }
    }

    /// Both exist: the Chief tab offers the switch.
    var canSwitch: Bool { hosted?.mainConversation != nil && placed?.mainConversation != nil }
}

/// The Chief the user picked for the Chief tab, kept on this Mac (client view state).
nonisolated enum HomeChiefChoice: String, Sendable {
    case hosted
    case placed

    private static let key = "home.chief.choice"

    @MainActor static func load(_ defaults: UserDefaults = .standard) -> HomeChiefChoice {
        defaults.string(forKey: key).flatMap(HomeChiefChoice.init(rawValue:)) ?? .hosted
    }

    @MainActor func save(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}

extension CloudChiefs {
    /// The name of the placed Chief once the Hosted Chief is the default.
    static var placedName: String {
        String(localized: "home.chief.placedName", defaultValue: "Chief (Mac mini)", table: "Cloud", bundle: .module)
    }

    /// The active chief with no machine placed: the default one, else the first.
    nonisolated static func hosted(in chiefs: [CloudChief]) -> CloudChief? {
        let hosted = chiefs.filter { $0.brainPlace == nil && $0.mainConversation != nil }
        return hosted.first(where: \.isDefault) ?? hosted.first
    }

    /// Makes sure the user has a Hosted Chief and that it is the default:
    /// `chief.create` under a fixed key when none exists. A placed chief
    /// still named plain "Chief" becomes "Chief (Mac mini)". No chief's
    /// `brain_place` changes. One revision conflict re-reads once.
    static func ensureHosted(call: Call) async throws -> HomeCloudChiefs {
        for attempt in 0..<2 {
            var chiefs = try await list(call: call)
            do {
                if hosted(in: chiefs) == nil {
                    // The fixed key makes one Hosted Chief across devices; when it replays a chief that
                    // is now placed or archived (not in the list as hosted), a fresh key makes a new one.
                    for key in ["chief-hosted-default", "chief-hosted-\(UUID().uuidString.lowercased())"] where hosted(in: chiefs) == nil {
                        let body: [String: Any] = ["op": "chief.create", "origin": "user", "idempotency_key": key,
                                                   "params": ["display_name": HomeStrings.chiefName, "is_default": true]]
                        guard CloudChief.parse(try CloudPairingSource.okValue(try await call("v1/ops", body))) != nil else {
                            throw FeedServiceError.badReply
                        }
                        chiefs = try await list(call: call)
                    }
                }
                if let placedChief = placed(in: chiefs), placedChief.displayName == HomeStrings.chiefName || placedChief.displayName.isEmpty {
                    let body: [String: Any] = ["op": "chief.update", "origin": "user", "idempotency_key": "chief-placed-rename-\(placedChief.id)-\(placedChief.rev)",
                                               "params": ["chief": placedChief.id, "expected_rev": placedChief.rev, "display_name": placedName]]
                    _ = try CloudPairingSource.okValue(try await call("v1/ops", body))
                    chiefs = try await list(call: call)
                }
                if let hostedChief = hosted(in: chiefs), !hostedChief.isDefault {
                    let body: [String: Any] = ["op": "chief.update", "origin": "user", "idempotency_key": "chief-hosted-default-\(hostedChief.id)-\(hostedChief.rev)",
                                               "params": ["chief": hostedChief.id, "expected_rev": hostedChief.rev, "is_default": true]]
                    _ = try CloudPairingSource.okValue(try await call("v1/ops", body))
                    chiefs = try await list(call: call)
                }
                return HomeCloudChiefs(hosted: hosted(in: chiefs), placed: placed(in: chiefs))
            } catch FeedServiceError.owner(code: "revision.conflict", message: _) where attempt == 0 {
                continue
            }
        }
        throw FeedServiceError.owner(code: "revision.conflict", message: "the chief changed on another device; try again")
    }
}
