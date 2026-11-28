import CmuxNextHomeModel
import CryptoKit
public import Foundation

/// A Chief's picture as the daemon's Chief registry keeps it: the bytes and their media type
/// (PNG, JPEG, GIF or WebP, at most 1 MiB; `chief.profile.avatar.set`).
public nonisolated struct ChiefAvatarPicture: Sendable, Equatable {
    /// The media type, for example `image/png`.
    public var mediaType: String
    /// The picture's bytes.
    public var data: Data

    /// - Parameters:
    ///   - mediaType: the media type of `data` (`image/png`, `image/jpeg`, `image/gif` or `image/webp`).
    ///   - data: the picture's bytes.
    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }

    /// The bytes' SHA-256 in lowercase hex, the registry's name for the picture. Stays on CryptoKit:
    /// the home rules have no hash op.
    public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The file extension for ``mediaType``: Rust's `chief_settings.pictureExtension`.
    var fileExtension: String {
        (try? HomeRules.call("chief_settings.pictureExtension", MediaRequest(mediaType: mediaType))) ?? "png"
    }

    private nonisolated struct MediaRequest: Encodable {
        var mediaType: String
    }
}
