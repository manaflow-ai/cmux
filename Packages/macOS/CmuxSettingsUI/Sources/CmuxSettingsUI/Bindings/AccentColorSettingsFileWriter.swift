import CmuxSettings
import Observation

/// Writes the Accent Color row's `app.accentColor` value to cmux.json, one
/// write at a time, always ending on the newest request.
///
/// cmux.json owns the value: after each write the host reloads the file,
/// which applies it to UserDefaults, and the row reads it back from there.
/// A color-well drag requests many values; while a write is in flight only
/// the newest request is kept, so writes never pile up and the last one wins.
/// ``requestedValue`` holds that newest request until every write finishes,
/// so the row shows the user's choice instead of an older value a reload
/// applied on the way.
@MainActor
@Observable
final class AccentColorSettingsFileWriter {
    /// The newest requested value while writes are outstanding, else `nil`.
    private(set) var requestedValue: String?

    @ObservationIgnored private var queuedValue: String?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private let write: @MainActor (String) async throws -> Void
    @ObservationIgnored private let didFail: @MainActor (Error) -> Void

    /// - Parameters:
    ///   - write: Persists one value to cmux.json and applies it.
    ///   - didFail: Reports a failed write. Later requests still run.
    init(
        write: @escaping @MainActor (String) async throws -> Void,
        didFail: @escaping @MainActor (Error) -> Void
    ) {
        self.write = write
        self.didFail = didFail
    }

    /// Queues `value`, replacing any queued value not yet written.
    func request(_ value: String) {
        requestedValue = value
        queuedValue = value
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Waits until every requested value has been written.
    func waitUntilIdle() async {
        await drainTask?.value
    }

    private func drain() async {
        while let value = queuedValue {
            queuedValue = nil
            do {
                try await write(value)
            } catch {
                didFail(error)
            }
        }
        requestedValue = nil
        drainTask = nil
    }
}

extension AccentColorSettingsFileWriter {
    /// The cmux.json key the Accent Color row writes. It shares its id with
    /// the UserDefaults-backed ``AppCatalogSection/accentColor``, which the
    /// settings file store fills from this value.
    static let settingsFileKey = JSONKey<String>(id: "app.accentColor", defaultValue: "cmux")
}
