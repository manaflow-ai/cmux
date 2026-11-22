import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Where browser profile records live and how edits reach them
/// (data-model.md 5). With `browser-profiles-v1` on the home daemon the
/// records are personal state there, copied once from this Mac's file;
/// without it they stay in the file. Deleted profiles' engine data is this
/// Mac's and stays tracked in the file either way.
extension BrowserProfileService {
    /// The home daemon serves browser profile records and this Mac's file
    /// records were copied there.
    var usesDaemonRecords: Bool { daemonServesRecords && book.recordsMigrated }

    var daemonServesRecords: Bool {
        let home = services.machines.local
        return home.supports(DaemonCapabilities.shared.browserProfiles) && home.store.personal.isLoaded
    }

    static func record(from snapshot: BrowserProfileSnapshot) -> BrowserProfileRecord {
        BrowserProfileRecord(id: snapshot.id, name: snapshot.name, color: snapshot.color, icon: snapshot.icon, position: snapshot.index,
                             source: snapshot.source)
    }

    // MARK: Edits

    /// Adds a profile; an existing id keeps its record (a retried import).
    /// Returns the id.
    func createProfile(id: String = BrowserProfileRecord.newID(), name: String, color: String?, icon: String?,
                       source: [String: String]? = nil) async throws -> String {
        guard usesDaemonRecords else {
            return try edit { try $0.create(id: id, name: name, color: color, icon: icon, source: source) }.id
        }
        guard BrowserProfileRecord.isValidID(id) else { throw BrowserProfileBookError.invalidID }
        let request = CreateBrowserProfileRequest(id: id, name: try BrowserProfileBook.validName(name),
                                                  color: try BrowserProfileBook.validColor(color),
                                                  icon: try BrowserProfileBook.validIcon(icon), source: source)
        guard let connection = services.machines.local.connection else { throw DaemonError.notConnected }
        return try await connection.createBrowserProfile(request).browserProfile.id
    }

    /// `createProfile` from a synchronous handler: validation errors throw
    /// now; the daemon write runs in the background.
    func createProfileNow(name: String, color: String?, icon: String?) throws {
        guard usesDaemonRecords else {
            try edit { try $0.create(name: name, color: color, icon: icon) }
            return
        }
        let request = CreateBrowserProfileRequest(id: BrowserProfileRecord.newID(), name: try BrowserProfileBook.validName(name),
                                                  color: try BrowserProfileBook.validColor(color),
                                                  icon: try BrowserProfileBook.validIcon(icon))
        services.machines.local.send("create-browser-profile") { try await $0.createBrowserProfile(request) }
    }

    func rename(_ id: String, to name: String) throws {
        guard usesDaemonRecords else { return try edit { try $0.rename(id, to: name) } }
        try update(UpdateBrowserProfileRequest(id: id, name: try BrowserProfileBook.validName(name)))
    }

    func setColor(_ id: String, _ color: String?) throws {
        guard usesDaemonRecords else { return try edit { try $0.setColor(id, color) } }
        let color = try BrowserProfileBook.validColor(color)
        try update(UpdateBrowserProfileRequest(id: id, color: color.map { .set($0) } ?? .clear))
    }

    func setIcon(_ id: String, _ icon: String?) throws {
        guard usesDaemonRecords else { return try edit { try $0.setIcon(id, icon) } }
        let icon = try BrowserProfileBook.validIcon(icon)
        try update(UpdateBrowserProfileRequest(id: id, icon: icon.map { .set($0) } ?? .clear))
    }

    private func update(_ request: UpdateBrowserProfileRequest) throws {
        guard isKnown(request.id) else { throw BrowserProfileBookError.unknownProfile }
        services.machines.local.send("update-browser-profile") { try await $0.updateBrowserProfile(request) }
    }

    // MARK: Migration and observation

    /// Watches the home daemon's personal state: the first time it serves
    /// browser profile records, this Mac's file records are copied there
    /// once; every later change of the records re-renders tabs and omnibars.
    func observeHomeRecords() {
        // task-owner: lives as long as the service; event-driven (Observation)
        homeRecordsObservation = Task { [weak self] in
            guard let store = self?.services.machines.local.store else { return }
            for await (serves, records) in Observations({ [weak self] in
                (self?.daemonServesRecords ?? false, store.personal.browserProfiles)
            }) {
                guard let self else { return }
                _ = records
                if serves, !book.recordsMigrated { await migrateRecordsToDaemon() }
                refreshPresentation()
            }
        }
    }

    /// Copies each file record into the home daemon (a create with the same
    /// id is idempotent there, so an interrupted copy resumes), including the
    /// default profile's name, color and icon when the user changed them.
    func migrateRecordsToDaemon() async {
        guard !migratingRecords, let connection = services.machines.local.connection else { return }
        migratingRecords = true
        defer { migratingRecords = false }
        do {
            for record in book.ordered {
                if record.isDefault {
                    let fresh = BrowserProfileBook().record(BrowserProfileRecord.defaultID)
                    guard record.name != fresh?.name || record.color != nil || record.icon != nil else { continue }
                    try await connection.updateBrowserProfile(UpdateBrowserProfileRequest(
                        id: record.id, name: record.name, color: record.color.map { .set($0) } ?? .unchanged,
                        icon: record.icon.map { .set($0) } ?? .unchanged))
                } else {
                    try await connection.createBrowserProfile(CreateBrowserProfileRequest(
                        id: record.id, name: record.name, color: record.color, icon: record.icon, source: record.source))
                }
            }
            try edit { $0.recordsMigrated = true }
        } catch {
            logger.error("copy browser profiles to the home daemon: \(String(describing: error), privacy: .public)")
        }
    }
}
