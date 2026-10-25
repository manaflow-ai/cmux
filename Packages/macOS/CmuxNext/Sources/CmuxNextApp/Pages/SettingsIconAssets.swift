import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Settings page's stored icons (cx-qno.2.3): `cmux-page://cmux.settings/icon/<ref>` answers a
/// PNG of a local daemon's `image:`/`svg:` asset, decoded as the sidebar draws it
/// (``IconAssetImages/decode(_:mediaType:)``), so the page never loads SVG markup itself.
enum SettingsIconAssets {
    static let prefix = "icon"

    /// The PNG of asset icon `icon` read from `owner`; nil for an emoji or symbol, or when it
    /// cannot be read or decoded.
    static func png(_ icon: String, owner: DaemonService?) async -> Data? {
        switch IconValue(wire: icon) {
        case .image?, .svg?: break
        default: return nil
        }
        guard let owner, owner.supports(DaemonCapability.iconAssets.rawValue), let connection = owner.connection,
              let blob = try? await IconAssetClient(connection).get(icon) else { return nil }
        return await encoded(blob.data, mediaType: blob.mediaType)
    }

    /// `data` decoded off the main actor and written as a PNG.
    @concurrent nonisolated static func encoded(_ data: Data, mediaType: String) async -> Data? {
        guard let image = IconAssetImages.decode(data, mediaType: mediaType) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }
}
