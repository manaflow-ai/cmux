import Foundation

extension LocalArtifactRepository {
    func ensureLoaded() throws {
        if let loadFailure { throw loadFailure }
        guard !loaded else { return }
        do {
            try prepareDirectories()
            guard fileManager.fileExists(atPath: paths.catalog.path) else {
                loaded = true
                return
            }
            guard !isSymlink(paths.catalog) else {
                throw ArtifactStoreError.corruptCatalog(paths.catalog.path)
            }
            let values = try paths.catalog.resourceValues(forKeys: [.fileSizeKey])
            guard let byteCount = values.fileSize,
                  byteCount >= 0,
                  byteCount <= configuration.maximumCatalogBytes else {
                throw ArtifactStoreError.corruptCatalog("catalog exceeds configured bound")
            }
            let data = try Data(contentsOf: paths.catalog, options: Data.ReadingOptions.mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded: [ArtifactRecord]
            if let document = try? decoder.decode(ArtifactCatalogDocument.self, from: data), document.version == 1 {
                decoded = document.records
            } else if let legacyArray = try? decoder.decode([ArtifactRecord].self, from: data) {
                decoded = legacyArray
            } else {
                throw ArtifactStoreError.corruptCatalog(paths.catalog.path)
            }
            recordsByIdentity.removeAll(keepingCapacity: true)
            // Decode a bounded global envelope, then apply the per-workspace
            // retention policy. Prefixing by the per-workspace limit here would
            // silently discard records from later workspaces on restart.
            for record in decoded.prefix(100_000) {
                let normalized = normalizedRecord(record)
                if let existing = recordsByIdentity[normalized.identityKey] {
                    recordsByIdentity[normalized.identityKey] = merge(existing, normalized)
                } else {
                    recordsByIdentity[normalized.identityKey] = normalized
                }
            }
            try enforceRetention(at: now())
            loaded = true
        } catch let error as ArtifactStoreError {
            loadFailure = error
            throw error
        } catch {
            let failure = ArtifactStoreError.corruptCatalog(error.localizedDescription)
            loadFailure = failure
            throw failure
        }
    }

    func persist() throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let document = ArtifactCatalogDocument(records: ordered(recordsByIdentity.values))
        let data = try encoder.encode(document)
        guard data.count <= configuration.maximumCatalogBytes else {
            throw ArtifactStoreError.catalogLimitExceeded
        }
        let temporaryURL = paths.root.appendingPathComponent(".catalog-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: Data.WritingOptions.atomic)
        guard paths.contains(temporaryURL), !isSymlink(temporaryURL) else {
            throw ArtifactStoreError.corruptCatalog(temporaryURL.path)
        }
        if fileManager.fileExists(atPath: paths.catalog.path) {
            _ = try fileManager.replaceItemAt(paths.catalog, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: paths.catalog)
        }
    }

    func prepareDirectories() throws {
        if fileManager.fileExists(atPath: paths.root.path), isSymlink(paths.root) {
            throw ArtifactStoreError.corruptCatalog(paths.root.path)
        }
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: paths.payloads.path), isSymlink(paths.payloads) {
            throw ArtifactStoreError.corruptCatalog(paths.payloads.path)
        }
        try fileManager.createDirectory(at: paths.payloads, withIntermediateDirectories: true)
    }

    func enforceRetention(at date: Date) throws {
        let normalized = configuration
        let cutoff = normalized.retentionAge > 0
            ? date.addingTimeInterval(-normalized.retentionAge)
            : nil
        // Count and age limits are per workspace. A single global cap would
        // let one noisy workspace evict another workspace's history.
        let groups = Dictionary(grouping: recordsByIdentity.values) { record in
            record.ownership.workspaceID ?? "<unowned>"
        }
        var retainedKeys = Set<String>()
        for group in groups.values {
            var values = group.filter { record in
                guard let cutoff else { return true }
                return record.isUserOwned || record.lastSeenAt >= cutoff
            }
            values.sort {
                if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let automatic = values.filter { !$0.isUserOwned }
            let pinned = values.filter(\.isUserOwned)
            let automaticSlots = max(0, normalized.retentionLimit - pinned.count)
            retainedKeys.formUnion(pinned.map(\.identityKey))
            retainedKeys.formUnion(automatic.prefix(automaticSlots).map(\.identityKey))
        }
        for (key, record) in recordsByIdentity where !retainedKeys.contains(key) {
            recordsByIdentity.removeValue(forKey: key)
            try removePayloadIfUnreferenced(record)
        }
        var payloadBytes: Int64 = 0
        let retainedRecords = recordsByIdentity.values.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for record in retainedRecords where record.representation.isManagedFile {
            guard let relative = record.representation.managedRelativePath else { continue }
            let url = paths.payloads.appendingPathComponent(relative)
            let size = (try? url.resourceValues(forKeys: Set([URLResourceKey.fileSizeKey])).fileSize).map(Int64.init) ?? 0
            if payloadBytes <= normalized.maximumPayloadBytes - size {
                payloadBytes += size
            } else if !record.isUserOwned {
                // Automatic payloads may be pruned to honor the aggregate
                // budget. Explicitly supplied files remain historical rows;
                // deleting their bytes behind the user's back would violate
                // the retention contract.
                recordsByIdentity.removeValue(forKey: record.identityKey)
                try removePayloadIfUnreferenced(record)
            }
        }
    }

    func removePayloadIfUnreferenced(_ record: ArtifactRecord) throws {
        guard let relative = record.representation.managedRelativePath else { return }
        let isReferenced = recordsByIdentity.values.contains { other in
            other.id != record.id && other.representation.managedRelativePath == relative
        }
        guard !isReferenced else { return }
        let url = paths.payloads.appendingPathComponent(relative)
        guard paths.contains(url), !isSymlink(url) else { return }
        try? fileManager.removeItem(at: url)
    }
}
