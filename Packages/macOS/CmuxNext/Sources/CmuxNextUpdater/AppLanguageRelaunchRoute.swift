public import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Settings > General > Language's relaunch row (`app.language`): `cmux.settings.language.relaunch {}`
/// relaunches the app so the menu bar and command names (made once per launch) take the new language,
/// keeping every session; the rest of the native text and the pages switch live.
@MainActor
public final class AppLanguageRelaunchRoute: PageProvider {
    public static let prefix = "cmux.settings.language."
    private let relaunch: @MainActor () -> Void

    init(relaunch: @escaping @MainActor () -> Void) {
        self.relaunch = relaunch
    }

    /// The relaunch a rollback takes: the updater's relaunch hook records the quit as keeping every
    /// session, then a helper reopens `app` once this process exits.
    public convenience init(updater: UpdaterService, app: URL) {
        self.init {
            updater.willRelaunch?()
            UpdateDropBack.relaunchAfterExit(app) {
                updater.log.append("language: the relaunch helper did not start; quit cmux to use the new language")
            }
        }
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.prefix + "relaunch" else { throw PageError.unknownOp(op) }
        // A relaunch quits the app: only the person's own click in the page.
        guard context.userGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "Relaunch needs the person's click")
        }
        relaunch()
        return .object([:])
    }
}
