public import AppKit
public import CmuxNextDesign
public import CmuxNextSettings
public import CmuxNextCompat
public import Foundation

/// The person's own backgrounds on the Settings page (backgrounds plan phase 3), beside the
/// picker and drop that `SettingsPageProvider` serves:
///
/// - `cmux.settings.backdrop.image.link {url}`: downloads an https image or movie and uses it,
///   as a picked file is used; `{id}`.
/// - `cmux.settings.backdrop.image.remove {id}`: deletes one of the folder's own images, never
///   the background in use (`cmux.settings.backdrop.in_use`); `{bytes}`.
/// - `cmux.settings.backdrop.image.reveal {id?}`: shows the image, or the folder, in Finder.
/// - `cmux.settings.backdrop.image.usage`: `{bytes, folder}`: what the folder's own images take, and
///   the folder (Shuffle Your Images is `folder:` it).
/// - `cmux.settings.backdrop.image.folder`: Shuffle a Folder…: the person picks a folder in the cmux
///   picker and the background shuffles its pictures (`folder:<absolute path>`); `{id}`, nil when
///   they left it. They chose it, so the write is theirs.
/// - `cmux.settings.backdrop.image.collage.save {collage}`: draws and saves a collage
///   (``BackdropCollages``); `{id}`, the page then sets `collage:<id>` like any choice.
/// - `cmux.settings.backdrop.image.collage.get {id}` / `.collage.delete {id}` (never the one in use).
///
/// Errors carry ``BackdropUserImages/ImportError`` codes, which the page words.
@MainActor
public final class BackdropImagesPageProvider: PageProvider {
    /// The ops this provider serves (longest prefix wins over `cmux.settings.`).
    public static let prefix = "cmux.settings.backdrop.image."

    private let images: BackdropUserImages
    private let use: @MainActor (URL) async throws -> String
    private let reveal: @MainActor ([URL]) -> Void
    private let inUse: @MainActor () -> BackdropSelection?
    private let settings: SettingsController?
    private let pickFolder: (@MainActor () async -> URL?)?

    /// `use` copies a file into the folder and makes it the background, returning its id (the
    /// picker's own path, so a link is checked and written as a picked file is).
    /// `inUse` is the background the app shows now, which remove refuses.
    public init(images: BackdropUserImages, use: @escaping @MainActor (URL) async throws -> String,
                inUse: @escaping @MainActor () -> BackdropSelection? = { nil },
                settings: SettingsController? = nil, pickFolder: (@MainActor () async -> URL?)? = nil,
                reveal: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.revealInBackground($0) }) {
        self.images = images
        self.use = use
        self.inUse = inUse
        self.settings = settings
        self.pickFolder = pickFolder
        self.reveal = reveal
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case Self.prefix + "link":
            guard let text = params["url"]?.stringValue,
                  let link = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw Self.error(.notHTTPS)
            }
            let file: URL
            do {
                file = try await BackdropUserImages.download(link)
            } catch let refused as BackdropUserImages.ImportError {
                throw Self.error(refused)
            }
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            return ["id": .string(try await use(file))]
        case Self.prefix + "remove":
            let selection = try own(params)
            // Removing a background something shows would leave its windows blank.
            guard await !isShown(selection) else {
                throw PageError(code: "cmux.settings.backdrop.in_use", message: "the background in use cannot be removed")
            }
            let images = images
            try await Task.detached { try images.remove(selection) }.value
            return try await usage()
        case Self.prefix + "reveal":
            if params["id"] != nil, case .file(let path) = try own(params) {
                reveal([URL(fileURLWithPath: path)])
            } else {
                reveal([images.folder])
            }
            return .object([:])
        case Self.prefix + "usage":
            return try await usage()
        case Self.prefix + "collage.save":
            let invalid = PageError(code: BackdropCollages.SaveError.invalid.code, message: "not a collage")
            guard let value = params["collage"],
                  let collage = try? JSONDecoder().decode(BackdropCollage.self, from: Data(value.compactText.utf8)) else { throw invalid }
            for layer in collage.layers { try await offered(layer.source) }
            let collages = collages
            do {
                return ["id": .string(try await Task.detached { try collages.save(collage) }.value)]
            } catch let refused as BackdropCollages.SaveError {
                throw PageError(code: refused.code, message: refused.code)
            }
        case Self.prefix + "collage.get":
            let collages = collages
            guard let id = params["id"]?.stringValue,
                  let collage = await Task.detached(operation: { collages.collage(id) }).value else { throw PageError.invalidParams("no such collage") }
            return try JSONValue.parse(JSONEncoder().encode(collage))
        case Self.prefix + "collage.delete":
            guard let id = params["id"]?.stringValue, BackdropCollages.isValidID(id) else { throw PageError.invalidParams("no such collage") }
            guard await !isShown(.collage(id: id)) else {
                throw PageError(code: "cmux.settings.backdrop.in_use", message: "the background in use cannot be removed")
            }
            let collages = collages
            try await Task.detached { try collages.delete(id) }.value
            return .object([:])
        case Self.prefix + "folder":
            guard let settings, let pickFolder else { throw PageError(code: "cmux.page.unavailable", message: "no settings or folder picker") }
            guard let folder = await pickFolder() else { return ["id": .null] }
            let id = BackdropSelectionSetting.folderPrefix + folder.standardizedFileURL.path
            try await settings.setSetting(at: BackdropSelectionSetting().configPath, to: .string(id), by: .user)
            return ["id": .string(id)]
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// The folder's own image `params.id` names; anything else is refused.
    private func own(_ params: JSONValue) throws -> BackdropSelection {
        guard let id = params["id"]?.stringValue, let selection = BackdropSelection(id: id), images.contains(selection) else {
            throw PageError.invalidParams("id is not one of your images")
        }
        return selection
    }

    /// Checks a collage layer is a picture the picker offers, readable now: a painting
    /// (downloaded first: most do not ship with cmux), a macOS wallpaper or one of your own
    /// images. Never any file by path: the page reads the collage's drawing back.
    private func offered(_ source: String) async throws {
        let invalid = PageError(code: BackdropCollages.SaveError.invalid.code, message: "not a picture the picker offers")
        switch BackdropSelection(id: source) {
        case .art(let art):
            guard await BackdropArtDownloads.shared.file(for: art) != nil else {
                throw PageError(code: BackdropCollages.SaveError.noPictures.code, message: "a painting did not download")
            }
        case .system(let path):
            let wallpapers = AppleWallpapers.system.desktopPictures.path + "/"
            guard URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(wallpapers) else { throw invalid }
        case let selection? where images.contains(selection):
            return
        default:
            throw invalid
        }
    }

    private func usage() async throws -> JSONValue {
        let images = images
        let bytes = await Task.detached { images.usage() }.value
        return ["bytes": .number(Double(bytes)), "folder": .string(images.folder.path)]
    }

    /// Whether the app's background or any workspace's own background is `selection`. Workspace
    /// backgrounds are the app's `workspace-backgrounds.json` beside the backgrounds folder
    /// (`WorkspaceBackgroundStore`): `{"<session>/<workspace>": "<background id>"}`.
    private func isShown(_ selection: BackdropSelection) async -> Bool {
        if selection == inUse() { return true }
        let file = images.folder.deletingLastPathComponent().appendingPathComponent("workspace-backgrounds.json")
        return await Task.detached { Self.aWorkspaceShows(selection, file: file) }.value
    }

    /// Read off the main actor. A file that does not read is taken to show it: removing a
    /// background can wait, a blank workspace cannot be undone.
    private nonisolated static func aWorkspaceShows(_ selection: BackdropSelection, file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let data = try? Data(contentsOf: file),
              let workspaces = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return workspaces.values.contains { ($0 as? String) == selection.id }
    }

    /// The person's collages, beside their own images.
    private var collages: BackdropCollages { BackdropCollages(folder: images.folder.appendingPathComponent("Collages", isDirectory: true)) }

    private static func error(_ refused: BackdropUserImages.ImportError) -> PageError {
        PageError(code: refused.code, message: refused.code)
    }
}

/// Where the Settings page keeps the person's own background images, and how it asks for one.
public struct SettingsBackdropImages {
    public let images: BackdropUserImages
    /// The cmux file picker; nil when the person left it.
    public let pick: @MainActor () async -> URL?

    public init(images: BackdropUserImages, pick: @escaping @MainActor () async -> URL?) {
        self.images = images
        self.pick = pick
    }
}
