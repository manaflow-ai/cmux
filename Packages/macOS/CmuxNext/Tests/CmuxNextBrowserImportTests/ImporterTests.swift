import Foundation
import Synchronization
import Testing
@testable import CmuxNextBrowserImport

/// Records batches; optionally fails for one profile.
final class RecordingDestination: ImportDestination {
    let batches = Mutex<[ImportBatch]>([])
    let failing: String?

    init(failing: String? = nil) { self.failing = failing }

    func commit(_ batch: ImportBatch) async throws {
        if batch.source.sourceKey == failing { throw CocoaError(.fileWriteNoPermission) }
        batches.withLock { $0.append(batch) }
    }
}

final class RecordingProvisioning: BrowserProfileProvisioning {
    let created = Mutex<[String]>([])
    func createProfile(id: String, name: String, color: String?, source: [String: String]) async throws -> String {
        created.withLock { $0.append("\(id)|\(name)|\(source["profile_dir"] ?? "")") }
        return id
    }
}

