public import Foundation

/// The one store of each Chief's picture: the daemon's Chief registry, which the `profile` and
/// `chiefs` tools, the CLI and the app all write. ``DaemonChiefAvatarRegistry`` is the app's;
/// tests pass an in-memory one.
public protocol ChiefAvatarRegistry: Sendable {
    /// Each Chief that has a picture, by participant id, with the picture's SHA-256: one cheap
    /// read (no bytes), so a picture is fetched only when it changed.
    /// - Throws: when the registry cannot be reached.
    func pictureRefs() async throws -> [String: String]
    /// Chief `chief`'s picture; nil when it has none.
    /// - Throws: when the registry cannot be reached.
    func picture(of chief: String) async throws -> ChiefAvatarPicture?
    /// Makes `picture` Chief `chief`'s picture.
    /// - Throws: when the registry cannot be reached or refuses the picture.
    func setPicture(_ picture: ChiefAvatarPicture, of chief: String) async throws
    /// Puts Chief `chief` back on the default picture.
    /// - Throws: when the registry cannot be reached.
    func clearPicture(of chief: String) async throws
}
