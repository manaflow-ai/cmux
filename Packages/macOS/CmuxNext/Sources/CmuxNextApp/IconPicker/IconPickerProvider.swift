import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The icon picker page's ops (`cmux.iconPicker.*`, webviews/src/pages/icon-picker/host.ts):
/// the session stream, the finish call, the recents/skin-tone prefs. Asset ops refuse until
/// the owner's blob store exists. The page owns no data.
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
    /// one now when it is loaded, else when it subscribes. `onFinish` runs once.
    func begin(_ session: IconPickerSession, onFinish: @escaping (IconPickerResult) -> Void) {
        finish(.cancel)
        self.session = session
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
        case "cmux.iconPicker.asset.put", "cmux.iconPicker.asset.fromURL":
            throw PageError.unavailable("icon assets need the owner's blob store")
        default:
            throw PageError.unknownOp(op)
        }
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
        return PageSubscription { [weak self] in self?.listener = nil }
    }

    /// Ends the open session once; later finishes (a double click, a late reply) do nothing.
    func finish(_ result: IconPickerResult) {
        guard let onFinish else { return }
        self.onFinish = nil
        onFinish(result)
    }
}
