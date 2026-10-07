import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// The page's JSON (CmuxNextSettings) and the daemon's wire JSON (CmuxNextDaemon) are two types.
private typealias PageJSON = CmuxNextSettings.JSONValue
private typealias WireJSON = CmuxNextDaemon.JSONValue

/// The icon picker's recents and skin tone (coordinator D3): one document in
/// the home session's personal projection `icon-picker.prefs`, so every
/// window and every client of the account share it. The page validates the
/// shape (recents.ts decodePrefs); this store keeps it, loads it on connect
/// and merges on a revision conflict (``IconPickerPrefs/merge(_:_:)``).
@MainActor
final class IconPickerPrefsStore {
    nonisolated static let subject = "icon-picker.prefs"
    nonisolated static let schemaVersion: UInt32 = 1

    /// Nil in tests: the document then lives in memory only.
    private weak var services: AppServices?
    private(set) var document: CmuxNextSettings.JSONValue = .null
    private var revision: UInt64?
    private var loaded = false

    init(services: AppServices?) {
        self.services = services
    }

    /// Loads the document once (the first picker open); later opens use the copy in memory.
    func load() {
        guard !loaded, let services else { return }
        loaded = true
        services.daemon.send("icon-picker-prefs-load") { [weak self] connection in
            let stored = try await connection.frontendProjection(subject: Self.subject)
            let revision = stored.projectionRevision
            let theirs: PageJSON? = stored.schemaVersion == Self.schemaVersion ? Self.page(stored.projection) : nil
            await MainActor.run {
                guard let self else { return }
                self.revision = revision
                if let theirs, theirs != .null { self.document = IconPickerPrefs.merge(theirs, self.document) }
            }
        }
    }

    func save(_ next: CmuxNextSettings.JSONValue) {
        document = next
        let revision = revision
        guard let services, let wire = Self.wire(next) else { return }
        services.daemon.send("icon-picker-prefs-save") { [weak self] connection in
            do {
                let stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: Self.schemaVersion,
                                                                        projection: wire, expectedRevision: revision)
                await MainActor.run { self?.revision = stored.projectionRevision }
            } catch DaemonError.command(_, let message, _, _, _) where message.contains("revision conflict") {
                let current = try await connection.frontendProjection(subject: Self.subject)
                let merged = IconPickerPrefs.merge(Self.page(current.projection) ?? .null, next)
                guard let mergedWire = Self.wire(merged) else { return }
                let stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: Self.schemaVersion,
                                                                        projection: mergedWire, expectedRevision: current.projectionRevision)
                await MainActor.run {
                    self?.document = merged
                    self?.revision = stored.projectionRevision
                }
            }
        }
    }
}

extension IconPickerPrefsStore {
    fileprivate nonisolated static func wire(_ value: PageJSON) -> WireJSON? {
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationObject) else { return nil }
        return try? JSONDecoder().decode(WireJSON.self, from: data)
    }

    fileprivate nonisolated static func page(_ value: WireJSON) -> PageJSON? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return PageJSON(foundation: object)
    }
}

/// The prefs document's merge rule, as plain values (unit tested).
nonisolated enum IconPickerPrefs {
    /// `ours` and `theirs` combined: every recent of both, each with the larger
    /// count and the later use; ours wins the skin tone. At most 36 recents
    /// (the page's MAX_RECENTS), most recent first.
    static func merge(_ theirs: CmuxNextSettings.JSONValue, _ ours: CmuxNextSettings.JSONValue) -> CmuxNextSettings.JSONValue {
        var byKey: [String: (count: Double, last: Double)] = [:]
        let entries: [CmuxNextSettings.JSONValue] = (theirs["recents"]?.arrayValue ?? []) + (ours["recents"]?.arrayValue ?? [])
        for entry in entries {
            guard let key = entry["key"]?.stringValue, let count = entry["count"]?.doubleValue, let last = entry["last"]?.doubleValue
            else { continue }
            let old = byKey[key]
            byKey[key] = (max(old?.count ?? 0, count), max(old?.last ?? 0, last))
        }
        let sorted = byKey.sorted { $0.value.last > $1.value.last || ($0.value.last == $1.value.last && $0.key < $1.key) }
        let recents: [CmuxNextSettings.JSONValue] = sorted.prefix(36).map { key, value in
            .object(["key": .string(key), "count": .number(value.count), "last": .number(value.last)])
        }
        let tone: CmuxNextSettings.JSONValue = ours["tone"] ?? theirs["tone"] ?? .number(0)
        return .object(["tone": tone, "recents": .array(recents)])
    }
}
