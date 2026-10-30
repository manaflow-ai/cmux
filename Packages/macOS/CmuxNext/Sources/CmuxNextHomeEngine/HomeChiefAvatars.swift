public import CmuxNextHome
public import Foundation

/// Each of this Mac's Chiefs' own avatar, keyed by participant id, for the Home list and each
/// Chief's header, and the one way the app changes a Chief's picture.
///
/// A Chief's picture lives in the daemon's Chief registry (``ChiefAvatarRegistry``), the store
/// the `profile` and `chiefs` tools and the CLI write, so a picture set anywhere shows here.
/// A text avatar (letters or an emoji) has no registry field and stays in that Chief's own
/// `optchat/profile.json`. A picture profile.json still names (from before) moves to the
/// registry once, after a copy of it and of profile.json goes to ``backupFolder``. Without a
/// registry (a cloud Chief), or while the daemon cannot be reached, the Chief's files are read.
///
/// ```swift
/// let avatars = HomeChiefAvatars(muxHome: home, registry: DaemonChiefAvatarRegistry(connection: connection))
/// let shown = await avatars.read(chiefs: ["agent_mux", "agent_scout01"])
/// ```
public nonisolated struct HomeChiefAvatars: Sendable {
    /// The folder beside profile.json that keeps a moved picture and the profile.json before the move.
    public static let backupFolder = "avatar-moved-to-registry"
    /// The default Chief's participant id.
    public static let defaultChief = HomeChiefName.muxID

    /// The default Chief's mux home (each other Chief's brain home is under it).
    private let muxHome: URL
    private let registry: (any ChiefAvatarRegistry)?
    /// Where the registry's pictures are kept as files, by SHA-256, for the views that draw a file.
    private let cache: URL

    /// - Parameters:
    ///   - muxHome: the default Chief's mux home (`HomeBrainHost.muxHome(tag:)`).
    ///   - registry: the daemon's Chief registry; nil reads and writes the Chief's files only.
    ///   - cache: the folder the registry's pictures are written to as files.
    public init(muxHome: URL, registry: (any ChiefAvatarRegistry)? = nil, cache: URL = HomeChiefAvatars.defaultCache) {
        self.muxHome = muxHome
        self.registry = registry
        self.cache = cache
    }

    /// The app's cache folder for Chief pictures.
    public static var defaultCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("ChiefAvatarRegistry", isDirectory: true)
    }

    /// The participant id of the Chief whose controls name `named` (nil: the default Chief).
    public static func chiefID(named: String?) -> String { named ?? defaultChief }

    private func files(_ chief: String) -> HomeChiefFiles {
        HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: muxHome, chief: chief == Self.defaultChief ? nil : chief))
    }

    /// The avatar of each Chief in `chiefs` (participant ids) that has one.
    public func read(chiefs: Set<String>) async -> [String: HomeChiefAvatar] {
        let refs: [String: String]?
        do { refs = try await registry?.pictureRefs() } catch { refs = nil }
        var avatars: [String: HomeChiefAvatar] = [:]
        for chief in chiefs {
            if let avatar = await read(chief: chief, refs: refs) { avatars[chief] = avatar }
        }
        return avatars
    }

    /// Chief `chief`'s avatar; nil when it has none (the default shows).
    public func read(chief: String) async -> HomeChiefAvatar? {
        await read(chiefs: [chief])[chief]
    }

    /// The header's avatar of Chief `chief`: its picture's bytes, else its text, else the bytes of
    /// the picture file `fallback` (the chosen pet character). Files are read off the main actor.
    public func headerAvatar(chief: String, fallback: URL?) async -> (text: String?, picture: Data?) {
        let avatar: (text: String?, picture: Data?)
        switch await read(chief: chief) {
        case .picture(let url)?: avatar = (nil, await Task.detached { try? Data(contentsOf: url) }.value)
        case .text(let text)?: avatar = (text, nil)
        case nil: avatar = (nil, nil)
        }
        return await Self.orFallback(avatar, fallback)
    }

    /// The header's avatar from a Chief's files alone (a cloud Chief has no registry here), else
    /// the bytes of `fallback`.
    public static func headerAvatar(files: HomeChiefFiles, fallback: URL?) async -> (text: String?, picture: Data?) {
        await orFallback(await Task.detached { files.headerAvatar() }.value, fallback)
    }

    private static func orFallback(_ avatar: (text: String?, picture: Data?), _ fallback: URL?) async -> (text: String?, picture: Data?) {
        guard avatar.text == nil, avatar.picture == nil, let fallback else { return avatar }
        return (nil, await Task.detached { try? Data(contentsOf: fallback) }.value)
    }

    /// `refs`: the registry's pictures (nil: no registry, or it cannot be reached).
    private func read(chief: String, refs: [String: String]?) async -> HomeChiefAvatar? {
        let files = files(chief)
        if let registry, let refs {
            if let sha = refs[chief] {
                if let cached = await cached(sha) { return cached }
                if let picture = try? await registry.picture(of: chief) { return await show(picture) }
            } else if let moved = await move(files, chief: chief, to: registry) {
                return await show(moved)
            }
        }
        return await Task.detached { files.tileAvatar() }.value
    }

    /// The cached file of the picture named `sha`, squared as the list draws it; nil when not cached.
    private func cached(_ sha: String) async -> HomeChiefAvatar? {
        let cache = cache
        return await Task.detached { () -> HomeChiefAvatar? in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
            guard let name = names.first(where: { ($0 as NSString).deletingPathExtension == sha }) else { return nil }
            let file = cache.appendingPathComponent(name)
            return .picture(HomeChiefFiles.squared(file) ?? file)
        }.value
    }

    /// Writes `picture` into the cache (once per SHA-256) and returns it as the list draws it.
    private func show(_ picture: ChiefAvatarPicture) async -> HomeChiefAvatar? {
        let cache = cache
        return await Task.detached { () -> HomeChiefAvatar? in
            let file = cache.appendingPathComponent("\(picture.sha256).\(picture.fileExtension)")
            if !FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                guard (try? picture.data.write(to: file, options: .atomic)) != nil else { return nil }
            }
            return .picture(HomeChiefFiles.squared(file) ?? file)
        }.value
    }

    /// Moves the picture profile.json still names into the registry, once: a backup of it and of
    /// profile.json first, then profile.json forgets it. Nil (nothing moved) when there is none,
    /// it is not a picture the registry keeps, or the registry refused it.
    private func move(_ files: HomeChiefFiles, chief: String, to registry: any ChiefAvatarRegistry) async -> ChiefAvatarPicture? {
        let found = await Task.detached { () -> ChiefAvatarPicture? in
            guard let file = files.legacyPictureFile(), let data = try? Data(contentsOf: file),
                  let type = registryMediaType(of: data) else { return nil }
            return ChiefAvatarPicture(mediaType: type, data: data)
        }.value
        guard let found, (try? await registry.setPicture(found, of: chief)) != nil else { return nil }
        await Task.detached {
            let folder = files.profileFile.deletingLastPathComponent()
            let backup = folder.appendingPathComponent(Self.backupFolder, isDirectory: true)
            try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            for name in [files.profileFile.lastPathComponent] + HomeChiefFiles.pictureFiles + [files.avatar() ?? ""] where !name.isEmpty {
                let from = folder.appendingPathComponent(name), to = backup.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                    try? FileManager.default.copyItem(at: from, to: to)
                }
            }
            files.clearPicture()
        }.value
        return found
    }

    /// Makes the picture `source` makes (``HomeChiefFiles/pictureData(from:)``) Chief `chief`'s:
    /// in the registry, and profile.json forgets any avatar of its own; without a registry, in the
    /// Chief's files.
    /// - Throws: when `source` is not a usable picture, or the registry cannot be reached or refuses it.
    public func setPicture(from source: URL, chief: String) async throws {
        let files = files(chief)
        try await setPicture(try await Task.detached { try files.pictureData(from: source) }.value, chief: chief)
    }

    /// Makes `picture` (a crop the person chose, ``HomeChiefPictureCrop``) Chief `chief`'s, as
    /// ``setPicture(from:chief:)`` does with a file's.
    /// - Throws: when the registry cannot be reached or refuses it, or the files cannot be written.
    public func setPicture(_ picture: ChiefAvatarPicture, chief: String) async throws {
        let files = files(chief)
        guard let registry else {
            try await Task.detached { try files.writePicture(picture) }.value
            return
        }
        try await registry.setPicture(picture, of: chief)
        await Task.detached { files.clearPicture() }.value
    }

    /// Puts Chief `chief` back on the default: no picture in the registry and no avatar in profile.json.
    /// - Throws: when the registry cannot be reached.
    public func clearPicture(chief: String) async throws {
        let files = files(chief)
        try await registry?.clearPicture(of: chief)
        await Task.detached { files.clearPicture() }.value
    }
}

/// The media type the registry keeps for `data` (PNG, JPEG, GIF or WebP, at most 1 MiB), from its bytes.
private nonisolated func registryMediaType(of data: Data) -> String? {
    guard data.count <= 1024 * 1024 else { return nil }
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
    if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
        return "image/webp"
    }
    return nil
}
