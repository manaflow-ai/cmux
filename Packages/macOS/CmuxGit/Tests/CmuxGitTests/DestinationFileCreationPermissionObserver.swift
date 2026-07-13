import Foundation

// This test-only FileManager is used by one task; observed creation state is
// confined to that serialized call path.
final class DestinationFileCreationPermissionObserver: FileManager, @unchecked Sendable {
    private let destinationRoot: URL
    private(set) var observedPermissions: [Int] = []

    init(destinationRoot: URL) {
        self.destinationRoot = destinationRoot.standardizedFileURL
        super.init()
    }

    override func createFile(
        atPath path: String,
        contents data: Data?,
        attributes attr: [FileAttributeKey: Any]? = nil
    ) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let isDestinationFile = url.path.hasPrefix(destinationRoot.path + "/")
        let creationAttributes = if isDestinationFile, attr == nil {
            [FileAttributeKey.posixPermissions: 0o644]
        } else {
            attr
        }
        let created = super.createFile(
            atPath: path,
            contents: data,
            attributes: creationAttributes
        )
        if created,
           isDestinationFile,
           let attributes = try? attributesOfItem(atPath: path),
           let permissions = attributes[.posixPermissions] as? Int {
            observedPermissions.append(permissions)
        }
        return created
    }
}
