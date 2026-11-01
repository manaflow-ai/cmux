public import CmuxNextHome
public import Foundation
import CmuxNextDaemon
import ImageIO
import UniformTypeIdentifiers

/// What the Chief settings show, read from this Chief's files and its brain.
public nonisolated struct HomeChiefSnapshot: Sendable {
    var harness: String?
    var model: String?
    var effort: String?
    /// engine.json's `speed` (`fast`), nil: the harness's own.
    var speed: String?
    var avatar: String?
    /// This Chief's acpmux has a CodeRouter Claude route (`claude-cr`).
    var routeConfigured = false
    /// The trace's last `turn.end`s, newest first.
    var turns: [HomeEngineTurn]
    /// The brain's `offered` lists (empty until the brain answers).
    var models: [ChiefEngineReport.Model] = []
    var efforts: [String] = []
    /// The speeds the turns' harness runs (`default`, and `fast` on codex).
    var speeds: [String] = []
    /// What the turns run on (engine.json over the brain's defaults), which
    /// names each picker's "Default"; nil until the brain answers.
    var effective: ChiefEngineReport.Engine?
    /// engine.json's reaction classifier fields (a416): this Chief's own values, nil: the person's
    /// (cmux.json `chief.reactionClassifier.*`, `chief.reactionsCanWake`). `reactionsCanWake` is
    /// "true" or "false".
    var classifierHarness: String?
    var classifierModel: String?
    var classifierPrompt: String?
    var reactionsCanWake: String?
    /// A hosted cloud Chief's brain is turned off: it answers no message (``HomeChiefHostedEngine``).
    var brainOff = false

    /// This snapshot with `report`'s offered models and efforts and its effective engine.
    func offering(_ report: ChiefEngineReport) -> HomeChiefSnapshot {
        var snapshot = self
        snapshot.models = report.offered.models
        snapshot.efforts = report.offered.efforts
        snapshot.speeds = report.offered.speeds
        snapshot.effective = report.engine
        // The brain's own engine.json, when it answered (a paired server's file is not this Mac's).
        if report.choice.classifierHarness != nil || report.choice.classifierModel != nil
            || report.choice.classifierPrompt != nil || report.choice.reactionsCanWake != nil {
            snapshot.classifierHarness = report.choice.classifierHarness
            snapshot.classifierModel = report.choice.classifierModel
            snapshot.classifierPrompt = report.choice.classifierPrompt
            snapshot.reactionsCanWake = report.choice.reactionsCanWake.map { $0 ? "true" : "false" }
        }
        return snapshot
    }
}

/// This Chief's files under its mux home: `optchat/engine.json` (the engine
/// optchat-chief reads at each turn start; read only here, the brain is its
/// one writer and a change goes through `chief.engine.set`),
/// `optchat/profile.json` (the avatar: text, or a picture file beside it) and `optchat/traces/` (read only). Blocking file I/O, so it runs
/// off the main actor.
public nonisolated struct HomeChiefFiles: Sendable {
    let muxHome: URL

    public init(muxHome: URL) {
        self.muxHome = muxHome
    }
    var engineFile: URL { muxHome.appendingPathComponent("optchat/engine.json") }
    var profileFile: URL { muxHome.appendingPathComponent("optchat/profile.json") }
    var traceDirectory: URL { muxHome.appendingPathComponent("optchat/traces", isDirectory: true) }
    /// The Chief home's acpmux config (`ChiefHome.acpmuxHome`), read only.
    var acpmuxConfigFile: URL { muxHome.appendingPathComponent("acpmux/config.json") }

    private func object(_ file: URL) -> [String: Any] {
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func snapshot() -> HomeChiefSnapshot {
        let choice = object(engineFile)
        let avatar = (object(profileFile)["avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var snapshot = HomeChiefSnapshot(harness: choice["harness"] as? String, model: choice["model"] as? String,
                                         effort: choice["effort"] as? String, avatar: avatar,
                                         routeConfigured: coderouterRouteConfigured(environment: ProcessInfo.processInfo.environment),
                                         turns: recentTurns(limit: 5))
        snapshot.speed = choice["speed"] as? String
        snapshot.classifierHarness = choice["classifier_harness"] as? String
        snapshot.classifierModel = choice["classifier_model"] as? String
        snapshot.classifierPrompt = choice["classifier_prompt"] as? String
        snapshot.reactionsCanWake = (choice["reactions_can_wake"] as? Bool).map { $0 ? "true" : "false" } ?? choice["reactions_can_wake"] as? String
        return snapshot
    }

    /// Whether this Chief's acpmux has a CodeRouter Claude route configured:
    /// `ACPMUX_CODEROUTER_CLAUDE_ROUTE` in the environment the Chief's acpmux
    /// inherits, else `coderouterClaudeRoute` in its config.json (acpmux
    /// `coderouter_claude_route`). Blank values do not count.
    func coderouterRouteConfigured(environment: [String: String]) -> Bool {
        let configured = { (value: String?) in !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        if let value = environment["ACPMUX_CODEROUTER_CLAUDE_ROUTE"] { return configured(value) }
        return configured(object(acpmuxConfigFile)["coderouterClaudeRoute"] as? String)
    }

    /// The avatar value alone (text or a picture's file name).
    func avatar() -> String? { snapshot().avatar }

    /// engine.json's harness, the brain's saved choice; nil when it saved none.
    func engineHarness() -> String? {
        (object(engineFile)["harness"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether an avatar value names a picture rather than text: a file
    /// name (no path) with an image extension, e.g. `"avatar": "cat.png"`.
    static func namesPicture(_ avatar: String) -> Bool {
        !avatar.contains("/") && pictureExtensions.contains((avatar as NSString).pathExtension.lowercased())
    }

    /// The picture files a profile may name (the Chief sheet's PNG, JPEG, GIF and WebP, and HEIC).
    static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]
    /// What Choose Picture… offers.
    static let pictureTypes: [UTType] = [.png, .jpeg, .heic, .gif, .webP]
    /// The largest GIF kept as it is (a still is drawn down instead): the daemon's own picture cap,
    /// which the Chief sheet keeps too.
    static let maximumGIFBytes = 1024 * 1024
    /// The pictures this writes beside profile.json; choosing another replaces them.
    static let pictureFiles = ["avatar.png", "avatar.gif"]

    /// The picture `source` makes, as the Chief's picture is kept: a GIF as it is, keeping its
    /// motion; a still drawn at 512 px as a PNG, so a large photo stays small.
    /// Throws when it is not a picture ImageIO reads, or a GIF over ``maximumGIFBytes``.
    public func pictureData(from source: URL) throws -> ChiefAvatarPicture {
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0,
              let type = (CGImageSourceGetType(image) as String?).flatMap(UTType.init) else { throw CocoaError(.fileReadCorruptFile) }
        if type.conforms(to: .gif) {
            let size = (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= Self.maximumGIFBytes else { throw CocoaError(.fileReadTooLarge) }
            return ChiefAvatarPicture(mediaType: "image/gif", data: try Data(contentsOf: source))
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512]
        let data = NSMutableData()
        guard let still = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(destination, still, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return ChiefAvatarPicture(mediaType: "image/png", data: data as Data)
    }

    /// Makes `source` the Chief's picture in its files (a cloud Chief's, which has no registry
    /// on this Mac): ``pictureData(from:)`` beside profile.json.
    public func writePicture(from source: URL) throws {
        try writePicture(try pictureData(from: source))
    }

    /// Makes `picture` the Chief's picture in its files, beside profile.json.
    public func writePicture(_ picture: ChiefAvatarPicture) throws {
        let folder = profileFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = picture.mediaType == "image/gif" ? "avatar.gif" : "avatar.png"
        let partial = folder.appendingPathComponent(name + ".app.tmp")
        try? FileManager.default.removeItem(at: partial)
        try picture.data.write(to: partial)
        for old in Self.pictureFiles { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(name))
        writeAvatar(name)
    }

    /// The picture file profile.json still names (from before the registry kept pictures), when it
    /// can be read; nil for a text avatar or none.
    func legacyPictureFile() -> URL? {
        guard let avatar = avatar(), Self.namesPicture(avatar) else { return nil }
        let file = profileFile.deletingLastPathComponent().appendingPathComponent(avatar)
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        return FileManager.default.isReadableFile(atPath: file.path) ? file : nil
    }

    /// Goes back to the bundled picture: no avatar, and the pictures this wrote removed.
    public func clearPicture() {
        writeAvatar("")
        let folder = profileFile.deletingLastPathComponent()
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        for old in Self.pictureFiles { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
    }

    /// The header's avatar from one profile read: its text, or the bytes of
    /// the picture it names (beside profile.json). A picture that cannot be
    /// read gives neither, so its file name never shows as text.
    public func headerAvatar() -> (text: String?, picture: Data?) {
        guard let avatar = (object(profileFile)["avatar"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return (nil, nil) }
        guard Self.namesPicture(avatar) else { return (avatar, nil) }
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        return (nil, try? Data(contentsOf: profileFile.deletingLastPathComponent().appendingPathComponent(avatar)))
    }

    /// The Chief tile's avatar from one profile read: the picture's file
    /// (beside profile.json, squared), else the text; nil when it sets none or its
    /// picture cannot be read, which the tile shows as the bundled cat.
    public func tileAvatar() -> HomeChiefAvatar? {
        guard let avatar = (object(profileFile)["avatar"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        guard Self.namesPicture(avatar) else { return .text(avatar) }
        let file = profileFile.deletingLastPathComponent().appendingPathComponent(avatar)
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        guard FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        return .picture(Self.squared(file) ?? file)
    }

    /// A stable short key of `path` (FNV-1a, as `ChiefHome.host` keys a mux home).
    private static func pathKey(_ path: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }

    /// A copy of a non-square picture cropped to its centred square, as the
    /// header draws it (the list stretches a picture over its disc), cached
    /// by its path, name and modification date (one copy per Chief); nil when
    /// it is square or unreadable.
    static func squared(_ file: URL) -> URL? {
        // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width != image.height else { return nil }
        let side = min(image.width, image.height)
        guard let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                     width: side, height: side)) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
            .appendingPathComponent("ChiefAvatar", isDirectory: true)
        let stamp = Int(modified?.timeIntervalSince1970 ?? 0)
        // Keyed by the picture's full path too: every Chief's file is `avatar.png`, so name and
        // time alone gave two Chiefs saved in the same second one tile.
        let copy = directory.appendingPathComponent("\(pathKey(file.path))-\(file.deletingPathExtension().lastPathComponent)-\(stamp).png")
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(copy as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, square, nil)
        return CGImageDestinationFinalize(destination) ? copy : nil
    }

    func writeAvatar(_ text: String) {
        var profile = object(profileFile)
        if text.isEmpty { profile.removeValue(forKey: "avatar") } else { profile["avatar"] = text }
        write(profile, to: profileFile)
    }

    /// 0600, through a temporary file and a replace, as optchat-chief writes.
    private func write(_ object: [String: Any], to file: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(file.lastPathComponent + ".app.tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data + Data("\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try? FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    /// The trace's last `turn.end`s, newest first (today's file, then yesterday's).
    func recentTurns(limit: Int) -> [HomeEngineTurn] {
        var found: [HomeEngineTurn] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        for offset in [0, -1] {
            let day = formatter.string(from: Date().addingTimeInterval(Double(offset) * 86_400))
            let file = traceDirectory.appendingPathComponent("\(day).jsonl")
            // concurrency-allow: HomeChiefFiles runs only inside Task.detached, never on the main actor
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"turn.end\"") {
                if let turn = HomeEngineTurn(line: String(line)) { found.append(turn) }
                if found.count >= limit { return found }
            }
        }
        return found
    }
}
