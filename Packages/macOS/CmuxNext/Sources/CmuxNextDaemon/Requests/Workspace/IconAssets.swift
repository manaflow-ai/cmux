public import Foundation

// `icon-assets-v1`: the owner's content-addressed icon asset store. `put-blob`
// stores one PNG, JPEG, WebP or SVG (the daemon sanitizes and validates an SVG)
// and returns the icon value that names it; icon fields then take that value.

/// One stored asset. `data` (base64) only in a `get-blob` reply.
public struct IconAssetBlob: Decodable, Sendable, Equatable {
    /// `blob:sha256-<hex>`.
    public var ref: String
    /// `image:sha256-<hex>` or `svg:sha256-<hex>`.
    public var icon: String
    public var mediaType: String
    public var size: Int
    public var data: String?

    enum CodingKeys: String, CodingKey {
        case ref, icon, size, data
        case mediaType = "media_type"
    }
}

/// `put-blob` (generated from the schema, swift_app/bindings.json): the generated memberwise init takes the base64
/// string; this one takes the asset's bytes.
extension PutBlobRequest {
    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data.base64EncodedString()
    }
}
