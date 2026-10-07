import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The icon picker page's ops (`cmux.iconPicker.*`, webviews/src/pages/icon-picker/host.ts):
/// the session stream, the finish call, the recents/skin-tone prefs. Asset ops refuse until
/// the owner's blob store exists. The page owns no data.
@MainActor
final class IconPickerProvider: PageProvider {
    static let sessionStream = "cmux.iconPicker.session"

    private var session: IconPickerSession
    private var listener: (@MainActor (JSONValue) -> Void)?
    private let prefs: IconPickerPrefsStore
    private let onFinish: (IconPickerResult) -> Void
    private var finished = false

    init(session: IconPickerSession, prefs: IconPickerPrefsStore, onFinish: @escaping (IconPickerResult) -> Void) {
        self.session = session
        self.prefs = prefs
        self.onFinish = onFinish
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.iconPicker.finish":
            guard let result = IconPickerResult.decode(params, session: session.id) else {
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
        // The page subscribes once it booted; the open session goes out at once.
        onEvent(session.event)
        return PageSubscription { [weak self] in self?.listener = nil }
    }

    /// Ends the session once; later finishes (a double click) do nothing.
    func finish(_ result: IconPickerResult) {
        guard !finished else { return }
        finished = true
        onFinish(result)
    }
}
