package import Foundation

/// The mount point and fallback detach device in the output of `hdiutil attach -plist`.
package struct DiskImageAttachment {
    package let mountPoint: URL?
    package let deviceEntry: String?

    package init(plist data: Data) {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        mountPoint = entities.compactMap { $0["mount-point"] as? String }.first { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        deviceEntry = entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
    }
}
