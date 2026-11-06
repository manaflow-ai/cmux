public import AppKit
public import CmuxNextBrowserAutomation
import CmuxNextDaemonService
public import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings
import Foundation
import os

/// The History page's Cookie Backups panel (decision D3 on cmux#13742): the app's own backups of an
/// agent's cookie clear in a WebKit tab, encrypted with this Mac's Keychain key, so only the app
/// lists and deletes them (native glue; the daemon never holds them). No cookie value reaches the
/// page.
///
/// - `cmux.history.cookie_backups.list {}` -> `{backups: [{id, site?, created_at_ms}]}`, newest first.
/// - `cmux.history.cookie_backups.delete {ids}` -> `{confirmed, deleted}`: only on the person's own
///   click in the page, and only after they confirm in the app's dialog (page script cannot answer
///   it): an agent can no longer undo those clears.
@MainActor
public final class HistoryCookieBackupsPageProvider: PageProvider {
    public static let prefix = "cmux.history.cookie_backups."
    private let backups: () -> CookieBackups?
    /// The page view the dialog attaches to.
    public var anchor: () -> NSView? = { nil }
    /// The person's answer to the delete question (tests answer it).
    public var confirm: (CmuxDialogSpec, NSWindow?) async -> Bool = { spec, window in
        await CmuxDialogCenter.shared.present(spec, in: window.map { .window($0) } ?? .app).button == "confirm"
    }

    public init(backups: @escaping () -> CookieBackups?) {
        self.backups = backups
    }

    public func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        switch op {
        case Self.prefix + "list":
            return ["backups": .array(await list().map(Self.json))]
        case Self.prefix + "delete":
            guard let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty else {
                throw PageError.invalidParams("ids must be a non-empty array of backup ids")
            }
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            guard await confirm(Self.question, anchor()?.window) else { return ["confirmed": false] }
            return ["confirmed": true, "deleted": CmuxNextSettings.JSONValue(await delete(ids))]
        default:
            throw PageError.unknownOp(op)
        }
    }

    /// The backups, newest first, read off the main actor (the files are decrypted with the Keychain key).
    public func list() async -> [CookieBackups.Summary] {
        guard let backups = backups() else { return [] }
        return await Task.detached {
            backups.pruneExpired()
            return backups.summaries()
        }.value
    }

    /// Deletes `ids` for good; answers how many went.
    public func delete(_ ids: [String]) async -> Int {
        guard let backups = backups() else { return 0 }
        let deleted = await Task.detached { ids.filter { (try? backups.remove($0)) != nil }.count }.value
        Self.logger.info("deleted \(deleted, privacy: .public) of \(ids.count, privacy: .public) cookie backups at the person's request")
        return deleted
    }

    private static func json(_ summary: CookieBackups.Summary) -> CmuxNextSettings.JSONValue {
        var object: [String: CmuxNextSettings.JSONValue] = [
            "id": .string(summary.restoreID),
            "created_at_ms": .number((summary.createdAt.timeIntervalSince1970 * 1_000).rounded()),
        ]
        if let site = summary.site { object["site"] = .string(site) }
        return .object(object)
    }

    static var question: CmuxDialogSpec {
        CmuxDialogSpec(title: HistoryCookieBackupStrings.confirmTitle, lines: [HistoryCookieBackupStrings.confirmMessage],
                       buttons: [.cancel(), CmuxDialogButton(id: "confirm", title: HistoryCookieBackupStrings.confirmDelete, role: .destructive)],
                       identifier: "cmux.history.cookieBackups.confirm")
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cookie-backups")
}

/// The delete question's strings (this target's Localizable.xcstrings); the panel's own are the page's.
nonisolated enum HistoryCookieBackupStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var confirmTitle: String { t("cookieBackups.confirm.title", "Delete these cookie backups?") }
    static var confirmMessage: String {
        t("cookieBackups.confirm.message", "An agent can no longer undo these cookie clears. You cannot undo this.")
    }
    static var confirmDelete: String { t("cookieBackups.confirm.delete", "Delete Backups") }
}
