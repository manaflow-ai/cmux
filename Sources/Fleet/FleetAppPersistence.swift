import CmuxFleet
import Foundation

/// Persists Fleet engine snapshots in Application Support.
@MainActor
final class FleetAppPersistence: FleetPersisting {
    private let fileURL: URL?
    private var lastData: Data?

    /// Creates a persistence store for the current app bundle.
    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fileURL = nil
            return
        }
        let bundleID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? bundleIdentifier!
            : "cmux"
        let safeBundleID = bundleID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        fileURL = appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("fleet-state-\(safeBundleID).json", isDirectory: false)
    }

    /// Writes the state snapshot, skipping byte-identical content.
    func save(_ state: FleetPersistedState) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            guard data != lastData else { return }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            lastData = data
        } catch {
#if DEBUG
            cmuxDebugLog("fleet.persistence.save.failed \(error.localizedDescription)")
#endif
        }
    }

    /// Loads the last valid snapshot, returning nil on missing or invalid data.
    func load() -> FleetPersistedState? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL)
        else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(FleetPersistedState.self, from: data)
            lastData = data
            return state
        } catch {
#if DEBUG
            cmuxDebugLog("fleet.persistence.load.failed \(error.localizedDescription)")
#endif
            return nil
        }
    }
}
