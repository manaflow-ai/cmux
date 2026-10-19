import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The person's own background (cx-t2x.8): an image chosen in the picker or dropped on the page is
/// copied into the backgrounds folder and set as `appearance.background`.
extension SettingsPageProvider {
    /// `cmux.settings.backdrop.choose_image`: the person picks an image; nil id when they left it.
    func chooseBackdropImage() async throws -> JSONValue {
        guard let backdropImages else { throw PageError(code: "cmux.page.unavailable", message: "no backgrounds folder") }
        guard let url = await backdropImages.pick() else { return ["id": .null] }
        return ["id": .string(try await useBackdropImage(url))]
    }

    /// `cmux.settings.art.search` (the works matching `query`) and `cmux.settings.art.use` (download
    /// the work `key`, copy it into the backgrounds folder and set it).
    func museumArt(_ op: String, params: JSONValue) async throws -> JSONValue {
        guard let museumArt else { throw PageError(code: "cmux.page.unavailable", message: "no museum search") }
        if op == "cmux.settings.art.search" {
            return await museumArt.find(params["query"]?.stringValue ?? "")
        }
        guard let key = params["key"]?.stringValue else { throw PageError.invalidParams("key is required") }
        guard let file = await museumArt.download(key: key) else {
            throw PageError(code: "cmux.settings.art.download", message: "\(key) could not be downloaded")
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return ["id": .string(try await useBackdropImage(file))]
    }

    /// Copies `url` into the backgrounds folder and makes it the background. The person chose the
    /// file (picker or drop), so the write is theirs.
    @discardableResult
    func useBackdropImage(_ url: URL) async throws -> String {
        guard let backdropImages else { throw PageError(code: "cmux.page.unavailable", message: "no backgrounds folder") }
        let descriptor = try Self.available(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath), "no background setting")
        let images = backdropImages.images
        let selection: BackdropSelection
        do {
            // The copy runs off the main actor: a photo can be tens of megabytes.
            selection = try await Task.detached { try images.adopt(url) }.value
        } catch {
            throw PageError(code: "cmux.settings.invalid", message: "\(url.lastPathComponent) cannot be used as a background")
        }
        // concurrency-allow: the settings owner writes through its CmuxConfigFile actor, off the main actor
        try await write(descriptor, .string(selection.id), by: .user)
        return selection.id
    }
}

/// Where the Settings page keeps the person's own background images, and how it asks for one.
struct SettingsBackdropImages {
    let images: BackdropUserImages
    /// The cmux file picker; nil when the person left it.
    let pick: @MainActor () async -> URL?
}
