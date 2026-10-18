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
/// - `cmux.settings.backdrop.image.usage`: `{bytes}` the folder's own images take.
/// - `cmux.settings.backdrop.image.collage.save {collage}`: draws and saves a collage
///   (``BackdropCollages``); `{id}`, the page then sets `collage:<id>` like any choice.
/// - `cmux.settings.backdrop.image.collage.get {id}` / `.collage.delete {id}` (never the one in use).
/// - `cmux.settings.backdrop.image.adjust`: places the picture a window shows by hand
///   (``BackdropAdjustOverlay``); `cmux.settings.backdrop.not_adjustable` when none shows one.
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
    private let adjust: @MainActor () -> Bool

    /// `use` copies a file into the folder and makes it the background, returning its id (the
    /// picker's own path, so a link is checked and written as a picked file is).
    /// `inUse` is the background the app shows now, which remove refuses.
    public init(images: BackdropUserImages, use: @escaping @MainActor (URL) async throws -> String,
                inUse: @escaping @MainActor () -> BackdropSelection? = { nil },
                reveal: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.revealInBackground($0) },
                adjust: @escaping @MainActor () -> Bool = { false }) {
        self.adjust = adjust
        self.images = images
        self.use = use
        self.inUse = inUse
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
            guard !isShown(selection) else {
                throw PageError(code: "cmux.settings.backdrop.in_use", message: "the background in use cannot be removed")
            }
            let images = images
            try await Task.detached { try images.remove(selection) }.value
            // Its hand placement goes with it.
            BackdropPlacementStore.shared.set(nil, for: selection.id)
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
            let collages = collages
            do {
                return ["id": .string(try await Task.detached { try collages.save(collage) }.value)]
            } catch let refused as BackdropCollages.SaveError {
                throw PageError(code: refused.code, message: refused.code)
            }
        case Self.prefix + "collage.get":
            guard let id = params["id"]?.stringValue, let collage = collages.collage(id) else { throw PageError.invalidParams("no such collage") }
            return try JSONValue.parse(JSONEncoder().encode(collage))
        case Self.prefix + "collage.delete":
            guard let id = params["id"]?.stringValue, BackdropCollages.isValidID(id) else { throw PageError.invalidParams("no such collage") }
            guard !isShown(.collage(id: id)) else {
                throw PageError(code: "cmux.settings.backdrop.in_use", message: "the background in use cannot be removed")
            }
            try collages.delete(id)
            BackdropPlacementStore.shared.set(nil, for: BackdropSelection.collage(id: id).id)
            return .object([:])
        case Self.prefix + "adjust":
            guard adjust() else {
                throw PageError(code: "cmux.settings.backdrop.not_adjustable", message: "no window shows a picture to place")
            }
            return .object([:])
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

    private func usage() async throws -> JSONValue {
        let images = images
        let bytes = await Task.detached { images.usage() }.value
        return ["bytes": .number(Double(bytes))]
    }

    /// Whether the app's background or any workspace's own background is `selection`. Workspace
    /// backgrounds are the app's `workspace-backgrounds.json` beside the backgrounds folder
    /// (`WorkspaceBackgroundStore`): `{"<session>/<workspace>": "<background id>"}`.
    private func isShown(_ selection: BackdropSelection) -> Bool {
        if selection == inUse() { return true }
        let file = images.folder.deletingLastPathComponent().appendingPathComponent("workspace-backgrounds.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        // A file that does not read is taken to show it: removing a background can wait, a blank
        // workspace cannot be undone.
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
