public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import Foundation

/// The App Store's New Tab choice (`tabs.newTabApp`): which installed app draws on the New Tab page
/// (`cmux.newtab/1`). The store's Use as New Tab and Stop Using as New Tab write it through the same
/// schema writer as the Settings page; nothing else in settings is reachable from the store.
///
/// - `cmux.apps.newtab.get` answers `{app}` (null when unset).
/// - `cmux.apps.newtab.set {app}` (an app id, or null to reset) only on the person's own click or
///   key in the page, written as theirs.
/// - `cmux.apps.newtab.changed` sends `{app}` each time the setting changes (any writer).
@MainActor
public final class AppsNewTabPageProvider: PageProvider {
    public static let prefix = "cmux.apps.newtab."
    private let settings: @MainActor @Sendable () -> SettingsController?
    /// The refusal a set without the person's own click or key shows (the app's shared sentence).
    private let personOnly: String

    public init(settings: @escaping @MainActor @Sendable () -> SettingsController?, personOnly: String) {
        self.settings = settings
        self.personOnly = personOnly
    }

    /// Its route on the App Store page; it goes before `cmux.apps.`, since Use as New Tab is the app's
    /// own setting, not a daemon op.
    public static func route(personOnly: String, settings: @escaping @MainActor @Sendable () -> SettingsController?) -> PageRoute {
        PageRoute(prefix: prefix, provider: AppsNewTabPageProvider(settings: settings, personOnly: personOnly))
    }

    private static func json(_ app: String?) -> JSONValue {
        ["app": app.map(JSONValue.string) ?? .null]
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let settings = settings() else { throw PageError.unavailable("settings are not loaded yet") }
        switch op {
        case "cmux.apps.newtab.get":
            return Self.json(settings.snapshot.newTabApp)
        case "cmux.apps.newtab.set":
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: personOnly)
            }
            let value: JSONValue?
            switch params["app"] {
            case .none, .some(.null): value = nil
            case let .some(.string(id)) where NewTabAppSetting.isValidID(id): value = .string(id)
            default: throw PageError.invalidParams("app must be an app id or null")
            }
            guard let descriptor = SettingsSchema.descriptor(for: NewTabAppSetting.configPath) else {
                throw PageError.unavailable("tabs.newTabApp is not a setting")
            }
            do {
                try await settings.setSetting(descriptor, to: value, by: .user)
            } catch let managed as SettingManaged {
                throw PageError(code: "cmux.settings.managed", message: String(describing: managed))
            }
            return Self.json(settings.snapshot.newTabApp)
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.apps.newtab.changed" else { throw PageError.unknownOp(stream) }
        let read = settings
        let task = Task {
            let (first, later) = ObservationStream.current { read()?.snapshot.newTabApp }
            var last = first
            for await app in later where app != last {
                last = app
                onEvent(Self.json(app))
            }
        }
        return PageSubscription { task.cancel() }
    }
}
