public import Foundation

/// One entry under the sidebar's Locations: a mounted volume.
public struct SidebarVolume: Sendable, Equatable, Identifiable {
    /// Its mount point.
    public let url: URL
    /// Its display name.
    public let name: String
    /// Whether it shows an Eject button (removable or ejectable media, disk images, network).
    public let isEjectable: Bool
    /// The mount point path.
    public var id: String { url.path }

    /// Makes an entry.
    public init(url: URL, name: String, isEjectable: Bool) {
        self.url = url
        self.name = name
        self.isEjectable = isEjectable
    }

    /// ``mounted()`` off the caller's actor: `mountedVolumeURLs` can wait seconds on a slow volume.
    @concurrent public static func read() async -> [SidebarVolume] { mounted() }

    /// The volumes mounted now, as Finder lists them (hidden volumes skipped). Blocks: call ``read()`` from the main actor.
    public static func mounted() -> [SidebarVolume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let ejectable = values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
                || values?.volumeIsLocal == false
            return SidebarVolume(url: url, name: values?.volumeLocalizedName ?? url.lastPathComponent,
                                 isEjectable: ejectable && url.path != "/")
        }
    }
}
