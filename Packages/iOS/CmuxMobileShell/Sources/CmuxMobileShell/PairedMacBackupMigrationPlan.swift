internal import CmuxMobilePairedMac

struct PairedMacBackupMigrationPlan {
    let primary: PairedMacBackupSnapshot
    let legacy: PairedMacBackupSnapshot

    var operations: [PairedMacBackupOp] {
        missingTombstoneIDs.sorted().map(deleteOp)
            + missingRecords.map { .upsert($0) }
    }

    func isFullyReconciled(by refreshed: PairedMacBackupSnapshot) -> Bool {
        let refreshedIDs = Set(refreshed.records.map(pairingID))
        let refreshedTombstones = Set(refreshed.deletedMacDeviceIDs)
        return missingRecords.allSatisfy({
            refreshedIDs.contains(pairingID($0))
        }) && missingTombstoneIDs.allSatisfy({
            refreshedTombstones.contains($0)
        })
    }

    private var missingTombstoneIDs: [String] {
        let currentIDs = Set(primary.records.map(pairingID))
        let currentTombstones = Set(primary.deletedMacDeviceIDs)
        return legacy.deletedMacDeviceIDs.filter { legacyTombstone in
            !currentIDs.contains(where: {
                tombstone(legacyTombstone, covers: $0)
            })
            && !currentTombstones.contains(where: {
                tombstone($0, covers: legacyTombstone)
            })
        }
    }

    private var missingRecords: [PairedMacBackupRecord] {
        let currentIDs = Set(primary.records.map(pairingID))
        let currentTombstones = Set(primary.deletedMacDeviceIDs)
        let legacyTombstones = Set(legacy.deletedMacDeviceIDs)
        return legacy.records.filter {
            let candidateID = pairingID($0)
            return !currentIDs.contains(candidateID)
                && !currentTombstones.contains(where: {
                    tombstone($0, covers: candidateID)
                })
                && !legacyTombstones.contains(where: {
                    tombstone($0, covers: candidateID)
                })
        }
    }

    private func pairingID(_ record: PairedMacBackupRecord) -> String {
        MobilePairedMac.pairingID(
            macDeviceID: record.macDeviceID,
            instanceTag: record.instanceTag
        )
    }

    private func tombstone(_ tombstoneID: String, covers pairingID: String) -> Bool {
        let tombstone = MobilePairedMac.pairingIdentity(from: tombstoneID)
        let pairing = MobilePairedMac.pairingIdentity(from: pairingID)
        guard tombstone.macDeviceID == pairing.macDeviceID else { return false }
        return tombstone.instanceTag == nil || tombstone.instanceTag == pairing.instanceTag
    }

    private func deleteOp(_ pairingID: String) -> PairedMacBackupOp {
        let identity = MobilePairedMac.pairingIdentity(from: pairingID)
        if let instanceTag = identity.instanceTag {
            return .deleteInstance(
                macDeviceID: identity.macDeviceID,
                instanceTag: instanceTag
            )
        }
        return .delete(macDeviceID: identity.macDeviceID)
    }
}
