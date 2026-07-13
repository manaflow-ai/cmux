import Foundation

// This test-only observer is used by one task; observed creation state is
// confined to that serialized call path.
final class DestinationFileCreationPermissionObserver: @unchecked Sendable {
    private(set) var observedPermissions: [Int] = []

    func observe(_ url: URL) {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[.posixPermissions] as? Int {
            observedPermissions.append(permissions)
        }
    }
}
