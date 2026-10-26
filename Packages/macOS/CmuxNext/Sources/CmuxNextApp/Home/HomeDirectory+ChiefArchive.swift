import CmuxNextHomeEngine
import CmuxNextHostedChief
import Foundation

/// Archive Chief for a cloud Chief. The row leaves the list on this Mac at once and stays gone
/// across launches (`archivedHere`); the cloud's `chief.archive` follows when it can run. Offline
/// or signed out, it runs at the next `chief.list` that answers. The default Chief (the Hosted
/// Chief always is) the cloud never archives (`chief_is_default`): it stays hidden on this Mac
/// only. A refusal for any other reason brings the row back and says why.
extension HomeDirectory {
    /// What Archive Chief did.
    enum ChiefArchiveOutcome: Equatable {
        /// The cloud archived it.
        case archived
        /// Hidden on this Mac; the cloud archive waits (offline, signed out, the default Chief).
        case hiddenHere
        /// Not archived, and shown again: the reason.
        case refused(String)
    }

    private enum CloudArchive {
        case done, waits, refused(String)
    }

    func archiveChief(_ id: String) async -> ChiefArchiveOutcome {
        setArchivedHere(id, true)
        switch await cloudArchive(id) {
        case .done: return .archived
        case .waits: return .hiddenHere
        case .refused(let reason):
            setArchivedHere(id, false)
            return .refused(reason)
        }
    }

    /// After a `chief.list` read: each Chief archived here whose cloud archive is still due gets
    /// it now; one the cloud lists as archived or deleted needs nothing more from this Mac.
    func syncArchivedHere() async {
        for id in archivedHere.sorted() {
            if hiddenCloudChiefs.contains(id) {
                setArchivedHere(id, false)
            } else if chiefs.contains(where: { $0.id == id && !$0.isDefault }) {
                if case .refused = await cloudArchive(id) { setArchivedHere(id, false) }
            }
        }
    }

    private func setArchivedHere(_ id: String, _ hidden: Bool) {
        if hidden { archivedHere.insert(id) } else { archivedHere.remove(id) }
        archiveStore.save(archivedHere)
    }

    /// `chief.archive` at the record's revision (history stays read-only); one revision conflict
    /// reads the list again and retries.
    private func cloudArchive(_ id: String) async -> CloudArchive {
        for attempt in 0..<2 {
            guard let record = chiefs.first(where: { $0.id == id }) else {
                if hiddenCloudChiefs.contains(id) { return finished(id) }
                return chiefsRead ? .refused(HomeStrings.archiveFailed) : .waits
            }
            if record.isDefault { return .waits }
            let body: [String: Any] = ["op": "chief.archive", "params": ["chief": id, "expected_rev": record.rev],
                                       "idempotency_key": "chief-archive-\(id)-\(record.rev)", "origin": "user"]
            do {
                _ = try Self.value(try await call("v1/ops", body))
                return finished(id)
            } catch FeedServiceError.owner(let code, _) where code == "revision.conflict" && attempt == 0 {
                guard await readChiefs() else { return .waits }
            } catch FeedServiceError.owner(let code, _) where code == "chief_is_default" {
                return .waits
            } catch FeedServiceError.owner(let code, _) where code == "selector.not_found" {
                return finished(id)
            } catch FeedServiceError.owner(_, let message) {
                return .refused(message.isEmpty ? HomeStrings.archiveFailed : message)
            } catch {
                // Signed out, offline, or no reply: the next list read sends it.
                return .waits
            }
        }
        return .waits
    }

    private func finished(_ id: String) -> CloudArchive {
        chiefs.removeAll { $0.id == id }
        hiddenCloudChiefs.insert(id)
        setArchivedHere(id, false)
        return .done
    }
}

/// Where `HomeDirectory.archivedHere` lives between launches.
struct HomeChiefArchiveStore {
    let defaults: UserDefaults
    var key = "home.chief.archivedHere"

    static var standard: HomeChiefArchiveStore { HomeChiefArchiveStore(defaults: .standard) }

    func load() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }

    func save(_ ids: Set<String>) {
        if ids.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(ids.sorted(), forKey: key) }
    }
}
