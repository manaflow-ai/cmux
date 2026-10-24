import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The icon picker page's ops (`cmux.iconPicker.*`, webviews/src/pages/icon-picker/host.ts):
/// the session stream, the finish call, the recents/skin-tone prefs, and the asset ops, which
/// store an Image or SVG with the session's owner (``IconAssetStore``) and refuse for a session
/// without one. The page owns no data.
///
/// One provider lives as long as the warm page (``IconPickerService``) and serves every picker
/// session in it: ``begin(_:onFinish:)`` swaps the session and pushes it through the page's one
/// subscription. The symbol catalog goes with the first event of each page load (a reload
/// after a crash too), never with a later session.
@MainActor
final class IconPickerProvider: PageProvider {
    static let sessionStream = "cmux.iconPicker.session"

    /// The session the page shows; nil before the first open.
    private(set) var session: IconPickerSession?
    private var onFinish: ((IconPickerResult) -> Void)?
    /// Where the open session's Image and SVG assets go; nil keeps those tabs off.
    private var assets: IconAssetStore?
    private var listener: (@MainActor (JSONValue) -> Void)?
    private let prefs: IconPickerPrefsStore
    private let catalog: IconPickerSymbolCatalog?
    private let maxEmojiVersion: Int?

    init(prefs: IconPickerPrefsStore, catalog: IconPickerSymbolCatalog? = nil, maxEmojiVersion: Int? = nil) {
        self.prefs = prefs
        self.catalog = catalog
        self.maxEmojiVersion = maxEmojiVersion
    }

    /// Whether a session waits for its outcome.
    var isOpen: Bool { onFinish != nil }

    /// Starts `session`: a session still open is cancelled first; the page resets to the new
    /// one now when it is loaded, else when it subscribes. `onFinish` runs once. With `assets`
    /// the page shows its Image and SVG tabs and stores their picks there.
    func begin(_ session: IconPickerSession, assets: IconAssetStore? = nil, onFinish: @escaping (IconPickerResult) -> Void) {
        finish(.cancel)
        var session = session
        session.assets = assets != nil
        self.session = session
        self.assets = assets
        self.onFinish = onFinish
        listener?(session.event)
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.iconPicker.finish":
            guard let session, let result = IconPickerResult.decode(params, session: session.id) else {
                throw PageError.invalidParams("finish: unknown session or invalid icon")
            }
            finish(result)
            return .null
        case "cmux.iconPicker.prefs.load":
            return prefs.document
        case "cmux.iconPicker.prefs.save":
            guard let document = params["prefs"], document.objectValue != nil else { throw PageError.invalidParams("prefs") }
            prefs.save(document)
            return .null
        case "cmux.iconPicker.asset.put":
            guard let assets else { throw PageError.unavailable("this icon takes no image or SVG") }
            guard let kind = params["kind"]?.stringValue.flatMap(IconAssetKind.init(rawValue:)),
                  let data = params["base64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  let mediaType = kind.mediaType(of: data) else { throw PageError.invalidParams("asset.put: kind and base64 data") }
            let opened = session?.id
            return try await stored(assets.put(mediaType, data), in: opened)
        case "cmux.iconPicker.asset.fromURL":
            guard let assets else { throw PageError.unavailable("this icon takes no image or SVG") }
            guard let kind = params["kind"]?.stringValue.flatMap(IconAssetKind.init(rawValue:)),
                  let url = params["url"]?.stringValue.flatMap(URL.init(string:)) else {
                throw PageError.invalidParams("asset.fromURL: kind and url")
            }
            let opened = session?.id
            let file = try await kind.download(url)
            guard session?.id == opened else { throw PageError.cancelled }
            return try await stored(assets.put(file.mediaType, file.data), in: opened)
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// The reply to an asset op started in session `opened`: refused when another session began
    /// meanwhile, so a late asset never lands in a newer picker.
    private func stored(_ icon: String, in opened: String?) throws -> JSONValue {
        guard session?.id == opened else { throw PageError.cancelled }
        return .object(["icon": .string(icon)])
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.sessionStream else { throw PageError.unknownOp(stream) }
        listener = onEvent
        // The page subscribes once per load: the current session (an empty one when no session is
        // open) goes out at once, with the catalog.
        var first = session ?? IconPickerSession(id: "", current: nil)
        first.catalog = catalog
        first.maxEmojiVersion = maxEmojiVersion
        onEvent(first.event)
        // Each event is the open session as it stands.
        return PageSubscription(freezing: .newest) { [weak self] in self?.listener = nil }
    }

    /// Ends the open session once; later finishes (a double click, a late reply) do nothing.
    func finish(_ result: IconPickerResult) {
        guard let onFinish else { return }
        self.onFinish = nil
        assets = nil
        onFinish(result)
    }
}
