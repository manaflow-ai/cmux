import CmuxNextCloud
import CmuxNextControl
import CmuxNextSettings
import CryptoKit
import Foundation

/// The Move to Cloud debug methods' names (DEBUG builds register them; a release router drops
/// every `debug.*` method). No relay may forward them (``RemoteRelayPolicy``).
enum DebugCloudMoveMethods {
    static let state = "debug.cloud.move_state"
    static let seed = "debug.cloud.move_seed"
}

/// `debug.cloud.move_state` and `debug.cloud.move_seed`, for the restore journey
/// (scripts/cmux-next/restore-journey.py, cx-h9os2): what Move to Cloud keeps in the app's
/// defaults (``CloudMoveSetup/ledger``), so a quit, an update relaunch or a crash can be
/// checked to keep it.
///
/// - `move_state {}`: the moved chats (``CloudMovedChats``), each chat's Retry after a stopped
///   move or Bring Back Local (``CloudMoveRetries``), the folders an agent's move starts in at
///   once ("Always", ``CloudMoveAsks``: grants of scope `folder`) and the launch offers Dismissed.
///   Ids, kinds, flags and digests only: a folder path, workspace name or move key is never
///   sent as text, only inside its record's digest (a change of any field changes it).
/// - `move_seed {run}`: records a Move to Cloud state of made-up machines named `rj-<run>-*`
///   (two moved chats, three move retries, a Bring Back Local retry, an Always folder and a
///   dismissed offer) through the same stores, after forgetting earlier `rj-` ones. No machine,
///   account or network is involved: no seeded chat is marked brought back, so nothing revokes.
/// - `move_seed {drop: kind}`: forgets the first `rj-` record of `kind` (`moved_chat`,
///   `move_retry`, `bring_back_retry`, `grant`, `dismissed`), to prove a check fails without it.
@MainActor
enum DebugCloudMove {
    /// Registers both methods in DEBUG builds; a release build registers neither.
    static func register(on router: ControlRouter?, services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        router?.register(methods(services))
        #endif
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension DebugCloudMove {
    static func methods(_ services: AppServices) -> [ControlMethod] {
        [
            .mainActor(DebugCloudMoveMethods.state) { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(state(services.cloud))
            },
            .mainActor(DebugCloudMoveMethods.seed) { [weak services] call in
                guard let cloud = services?.cloud else { return .value(.null) }
                if let kind = call.params["drop"]?.stringValue {
                    return .value(.object(["dropped": .bool(try drop(kind, cloud))]))
                }
                guard let run = call.params["run"]?.stringValue, !run.isEmpty,
                      run.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                    throw ControlError.invalidParams("needs run (letters and digits) or drop")
                }
                try seed(run, cloud)
                return .value(state(cloud))
            },
        ]
    }

    static func state(_ cloud: CloudService) -> JSONValue {
        let chats = cloud.movedChats.all().sorted { ($0.host, $0.session) < ($1.host, $1.session) }
        let moveRetries = retries(cloud.moveRetries)
        let defaults = cloud.move.ledger
        let folders = (defaults?.stringArray(forKey: CloudMoveAsks.defaultsKey) ?? []).sorted()
        let dismissed = defaults?.dictionary(forKey: CloudMoveAsks.dismissedKey) as? [String: String] ?? [:]
        return .object([
            "moved_chats": .array(chats.map { entry in
                .object([
                    "machine_id": .string(entry.machineID),
                    "host": .string(entry.host),
                    "session": .string(entry.session),
                    "harness": entry.harness.map(JSONValue.string) ?? .null,
                    "named": .bool(entry.name != nil),
                    "brought_back": .bool(entry.broughtBack != nil),
                    "digest": .string(digest(entry)),
                ])
            }),
            "move_retries": .array(moveRetries),
            "bring_back_retries": .array(retries(cloud.bringBackRetries)),
            "grants": .array(folders.map { .object(["id": .string(digest($0)), "scope": .string("folder"), "kind": .string("always_move")]) }),
            // Whether each dismissed offer still matches its tab's Retry (a new Retry offers again).
            "dismissed": .array(dismissed.keys.sorted().map { tab in
                .object(["tab": .string(tab),
                         "matches_retry": .bool(cloud.moveRetries[tab].map { CloudMoveAsks.fingerprint($0) } == dismissed[tab])])
            }),
        ])
    }

    private static func retries(_ store: CloudMoveRetries) -> [JSONValue] {
        store.tabs.compactMap { tab in
            guard let retry = store[tab] else { return nil }
            let kind = switch retry {
            case .move: "move"
            case .show: "show"
            case .askFirst: "ask_first"
            case .update: "update"
            }
            let machine: String? = switch retry {
            case .show(let shown): shown.machineID
            default: retry.machineID
            }
            return .object(["tab": .string(tab), "kind": .string(kind), "machine_id": machine.map(JSONValue.string) ?? .null,
                            "digest": .string(digest(retry))])
        }
    }

    private static func seed(_ run: String, _ cloud: CloudService) throws {
        guard let defaults = cloud.move.ledger else { throw ControlError.invalidParams("no ledger defaults") }
        forgetSeeded(cloud, defaults)
        let id = "rj-\(run)"
        let machine = "\(id)-machine", folder = "/tmp/\(id)/project"
        cloud.movedChats.record(CloudMovedChats.Entry(
            machineID: machine, host: "registry:\(id)-store", session: "\(id)-chat-a", harness: "claude",
            localRoot: folder, localChat: folder, remoteFolder: "/home/cmux/work/project", remoteChat: "/home/cmux/work/project",
            name: "\(id) chat", broughtBack: nil))
        cloud.movedChats.record(CloudMovedChats.Entry(
            machineID: "\(id)-machine-2", host: "registry:\(id)-store-2", session: "\(id)-chat-b", harness: nil,
            localRoot: folder, localChat: folder + "/sub", remoteFolder: "/root/work/project", remoteChat: "/root/work/project/sub",
            name: nil, broughtBack: nil))
        cloud.moveRetries["\(id)-tab-move"] = .move(machineID: machine)
        cloud.moveRetries["\(id)-tab-show"] = .show(CloudMoveRetries.Shown(
            session: "\(id)-chat-a", harness: "claude", machineID: machine, folder: "/home/cmux/work/project",
            name: "\(id) chat", key: "\(id)-move-key", host: nil, movedSession: nil))
        cloud.moveRetries["\(id)-tab-update"] = .update(machineID: "\(id)-machine-2")
        cloud.bringBackRetries["\(id)-tab-back"] = .askFirst(machineID: machine)
        defaults.set(((defaults.stringArray(forKey: CloudMoveAsks.defaultsKey) ?? []) + [folder]).sorted(), forKey: CloudMoveAsks.defaultsKey)
        var dismissed = defaults.dictionary(forKey: CloudMoveAsks.dismissedKey) as? [String: String] ?? [:]
        dismissed["\(id)-tab-move"] = CloudMoveAsks.fingerprint(.move(machineID: machine))
        defaults.set(dismissed, forKey: CloudMoveAsks.dismissedKey)
    }

    /// Forgets every earlier `rj-` record, so runs on one tag never add up.
    private static func forgetSeeded(_ cloud: CloudService, _ defaults: UserDefaults) {
        for entry in cloud.movedChats.all() where entry.machineID.hasPrefix("rj-") {
            cloud.movedChats.forget(host: entry.host, session: entry.session)
        }
        for store in [cloud.moveRetries, cloud.bringBackRetries] {
            for tab in store.tabs where tab.hasPrefix("rj-") { store[tab] = nil }
        }
        let folders = defaults.stringArray(forKey: CloudMoveAsks.defaultsKey) ?? []
        defaults.set(folders.filter { !$0.hasPrefix("/tmp/rj-") }, forKey: CloudMoveAsks.defaultsKey)
        let dismissed = defaults.dictionary(forKey: CloudMoveAsks.dismissedKey) as? [String: String] ?? [:]
        defaults.set(dismissed.filter { !$0.key.hasPrefix("rj-") }, forKey: CloudMoveAsks.dismissedKey)
    }

    private static func drop(_ kind: String, _ cloud: CloudService) throws -> Bool {
        guard let defaults = cloud.move.ledger else { throw ControlError.invalidParams("no ledger defaults") }
        switch kind {
        case "moved_chat":
            let seeded = cloud.movedChats.all().filter { $0.machineID.hasPrefix("rj-") }.sorted { ($0.host, $0.session) < ($1.host, $1.session) }
            guard let first = seeded.first else { return false }
            cloud.movedChats.forget(host: first.host, session: first.session)
        case "move_retry", "bring_back_retry":
            let store = kind == "move_retry" ? cloud.moveRetries : cloud.bringBackRetries
            guard let tab = store.tabs.first(where: { $0.hasPrefix("rj-") }) else { return false }
            store[tab] = nil
        case "grant":
            var folders = (defaults.stringArray(forKey: CloudMoveAsks.defaultsKey) ?? []).sorted()
            guard let index = folders.firstIndex(where: { $0.hasPrefix("/tmp/rj-") }) else { return false }
            folders.remove(at: index)
            defaults.set(folders, forKey: CloudMoveAsks.defaultsKey)
        case "dismissed":
            var dismissed = defaults.dictionary(forKey: CloudMoveAsks.dismissedKey) as? [String: String] ?? [:]
            guard let tab = dismissed.keys.sorted().first(where: { $0.hasPrefix("rj-") }) else { return false }
            dismissed[tab] = nil
            defaults.set(dismissed, forKey: CloudMoveAsks.dismissedKey)
        default:
            throw ControlError.invalidParams("drop: moved_chat, move_retry, bring_back_retry, grant or dismissed")
        }
        return true
    }

    /// 16 hex digits of the record's SHA-256 (its JSON with sorted keys): equal records, equal digests.
    private static func digest(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
