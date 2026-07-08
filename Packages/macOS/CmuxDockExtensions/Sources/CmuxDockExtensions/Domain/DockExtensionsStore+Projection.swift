import Foundation

/// Filesystem projection helpers for `DockExtensionsStore`: staged-checkout
/// promotion into the managed checkouts directory, and the pure
/// lockfile-record → `InstalledDockExtension` projection used by `reload()`.
/// All helpers are `nonisolated static` — they run on detached projection
/// tasks or service actors, never on the main actor.
extension DockExtensionsStore {
    nonisolated static func moveIntoPlace(staging: URL, destination: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw DockExtensionError.stagingFailed(detail: error.localizedDescription)
        }
    }

    nonisolated static func project(
        records: [DockExtensionInstallRecord],
        directories: DockExtensionDirectories,
        loader: DockExtensionManifestLoader
    ) -> [InstalledDockExtension] {
        records.map { record in
            let root = rootDirectory(for: record, directories: directories)
            do {
                let manifest = try loader.load(fromDirectory: root)
                let status: InstalledDockExtension.Status
                if manifest.id != record.id {
                    status = .needsReconsent
                } else if record.source.isLocal {
                    // Linked development extensions are trusted live; edits to
                    // the manifest are the whole point of linking.
                    status = .ok
                } else {
                    let fingerprint = manifest.consentFingerprint(pinnedSha: record.pinnedSha)
                    status = fingerprint == record.consentFingerprint ? .ok : .needsReconsent
                }
                return InstalledDockExtension(
                    record: record,
                    manifest: manifest,
                    rootDirectory: root,
                    status: status
                )
            } catch {
                let message = (error as? DockExtensionError)?.errorDescription ?? error.localizedDescription
                return InstalledDockExtension(
                    record: record,
                    manifest: nil,
                    rootDirectory: root,
                    status: .manifestUnavailable(message)
                )
            }
        }
    }

    nonisolated static func rootDirectory(
        for record: DockExtensionInstallRecord,
        directories: DockExtensionDirectories
    ) -> URL {
        switch record.source {
        case .local(let path):
            return URL(fileURLWithPath: path, isDirectory: true)
        case .github:
            // A malformed lockfile id (other tooling writes this file) must
            // never resolve to a path outside the managed checkouts directory;
            // route it to a never-existing child so the projection reports the
            // record as unavailable instead of reading a traversal target.
            guard DockExtensionManifest.isValidExtensionId(record.id) else {
                return directories
                    .checkoutDirectory(id: "invalid")
                    .appendingPathComponent("invalid-record-id", isDirectory: true)
            }
            return applySubdirectory(
                record.source.subdirectory,
                to: directories.checkoutDirectory(id: record.id)
            )
        }
    }

    nonisolated static func applySubdirectory(_ subdirectory: String?, to base: URL) -> URL {
        guard let subdirectory else { return base }
        return base.appendingPathComponent(subdirectory, isDirectory: true)
    }
}
