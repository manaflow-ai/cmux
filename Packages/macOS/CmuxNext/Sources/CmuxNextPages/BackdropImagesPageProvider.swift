public import AppKit
public import CmuxNextDesign
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
                adjust: @escaping @MainActor () -> Bool = BackdropImagesPageProvider.adjustFrontWindow) {
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
            // Removing the background in use would leave every window blank.
            guard selection != inUse() else {
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

    /// Places the picture in the frontmost window that shows one, and brings it forward.
    public static func adjustFrontWindow() -> Bool {
        guard let window = NSApp.orderedWindows.first(where: { $0.isVisible && WindowMaterialView.backdrop(of: $0)?.adjustable != nil }),
              BackdropAdjustOverlay.begin(in: window) else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

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
