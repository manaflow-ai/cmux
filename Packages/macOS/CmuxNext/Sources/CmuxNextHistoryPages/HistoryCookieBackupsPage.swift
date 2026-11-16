public import AppKit
public import CmuxNextBrowserAutomation
import CmuxNextDaemonService
public import CmuxNextDesign
public import CmuxNextHistory
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
///   click in the page (each click once), and only after they confirm in the app's dialog (page
///   script cannot answer it): an agent can no longer undo those clears.
///
/// Every other `cmux.history.` call and stream goes to `relay` (the daemon), but the list, remove
/// and clear go to ``history``, the app's own History path (as the native page): the list merges
/// every machine's command rows and greys unreachable locations, and the entries it showed (``shown``,
/// this page's own) are what a remove or an open acts on, older search hits included, whatever another
/// page lists; a remove or clear also drops the pages
/// from every profile's omnibar suggestions. A remove or clear (``gestureOperations``) goes only on
/// the person's own click, each click once, whatever the daemon checks (cmux#37302).
@MainActor
public final class HistoryCookieBackupsPageProvider: PageProvider {
    public static let prefix = "cmux.history.cookie_backups."
    /// The History page's mutations that need the person's gesture (cmux-tui/spec/page-router.json `history.gesture`).
    public static let gestureOperations: Set<String> = ["cmux.history.entries.remove", "cmux.history.site.remove", "cmux.history.clear"]
    private let backups: () -> CookieBackups?
    /// The daemon relay for the rest of `cmux.history.`; none answers `unknown_op`.
    public var relay: (any PageProvider)?
    /// The app's History owner for the list, remove and clear (HistoryService, as the native page); nil relays them.
    public weak var history: (any HistoryPageEditing)?
    /// The entries this page's last list showed, by id: a remove or an open of one acts on it (HistoryService.entry(id:)).
    public private(set) var shown: [String: HistoryEntry] = [:]
    /// The gesture (its event's uptime) the last delete, remove or clear spent.
    private var spentGesture: TimeInterval?
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
            let ids = try Self.ids(params)
            // One click, one question: a second delete off the same gesture is refused, so a page
            // script cannot stack confirmation dialogs on one click.
            try spendGesture(context)
            guard await confirm(Self.question, anchor()?.window) else { return ["confirmed": false] }
            return ["confirmed": true, "deleted": CmuxNextSettings.JSONValue(await delete(ids))]
        default:
            guard let relay, op.hasPrefix("cmux.history.") else { throw PageError.unknownOp(op) }
            if op == "cmux.history.entries.list", let history {
                let read = try await history.list(params)
                shown = Dictionary(read.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                // The daemon's row shape (webviews/src/pages/history/types.ts), and its `pending_kinds` when the list is not complete.
                var reply: [String: CmuxNextSettings.JSONValue] = ["entries": .array(read.entries.map(\.pageJSON)), "revision": .number(0)]
                if !read.pending.isEmpty { reply["pending_kinds"] = .array(read.pending.map(\.rawValue).sorted().map(CmuxNextSettings.JSONValue.string)) }
                return .object(reply)
            }
            guard Self.gestureOperations.contains(op) else { return try await relay.call(op, params: params, context: context) }
            try spendGesture(context)
            guard let history else { return try await relay.call(op, params: params, context: context) }
            try await history.apply(op, params)
            return ["ok": true]
        }
    }

    public func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        guard let relay else { throw PageError.unknownOp(stream) }
        return try await relay.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }

    /// A mutation runs only on the person's own key or pointer event, one per event.
    private func spendGesture(_ context: PageCallContext) throws {
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
        spentGesture = event
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

    /// `ids`: a non-empty array of distinct non-empty backup ids; anything else is refused (a
    /// mixed array is not read as its string part).
    static func ids(_ params: CmuxNextSettings.JSONValue) throws -> [String] {
        let refused = PageError.invalidParams("ids must be a non-empty array of backup ids")
        guard case .array(let items)? = params["ids"], !items.isEmpty else { throw refused }
        let ids = try items.map { item -> String in
            guard case .string(let id) = item, !id.isEmpty else { throw refused }
            return id
        }
        guard Set(ids).count == ids.count else { throw refused }
        return ids
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
