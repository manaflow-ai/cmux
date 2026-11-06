import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextStash
import Foundation

/// The Stashed Tabs page's `cmux.stash.*` (webviews/src/pages/stash). The daemon owns the stashes:
/// `stash.list`, `stash.import` (with the app's browser engine added) and the `stash-changed`
/// stream go through the page relay. Two ops stay in the app, as native glue:
///
/// - `cmux.stash.restore {stash, members?, new_workspace?}`: only the app knows the pane a page
///   reopens in and shows what came back.
/// - `cmux.stash.delete {stash, members?}`: on the person's click, the page's members hide while
///   the app's Undo toast is up; the delete goes to the daemon when the toast ends without Undo.
///   Answers `{deleted}` then (false: Undo).
@MainActor
final class StashPageProvider: PageProvider {
    private let stash: StashService
    private let relay: any PageProvider
    /// The page view whose window shows the Undo toast.
    var anchor: () -> NSView? = { nil }

    init(stash: StashService, relay: any PageProvider) {
        self.stash = stash
        self.relay = relay
    }

    func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        switch op {
        case "cmux.stash.restore":
            let id = try Self.stashID(params)
            try await run { try await self.stash.restore(id, members: Self.members(params), inNewWorkspace: params["new_workspace"]?.boolValue == true) }
            return ["restored": true]
        case "cmux.stash.delete":
            let id = try Self.stashID(params)
            guard context.userGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            let members = Self.members(params)
            guard await undoToast(id: id, members: members) else { return ["deleted": false] }
            try await run { try await self.stash.delete(id, members: members) }
            return ["deleted": true]
        case "cmux.stash.import":
            var members = params.objectValue ?? [:]
            members["engine"] = .string(stash.importEngine)
            return try await relay.call(op, params: .object(members), context: context)
        default:
            return try await relay.call(op, params: params, context: context)
        }
    }

    func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        try await relay.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }

    /// "Stashed tab deleted" (or group) with Undo in the page's window; true when it ended without
    /// Undo. Without a window the delete goes at once.
    private func undoToast(id: String, members: [String]?) async -> Bool {
        guard let window = anchor()?.window else { return true }
        let message = members == nil ? StashPageStrings.deletedGroup : StashPageStrings.deletedTab
        let toast = CmuxToast(id: "stash.delete.\(id).\(members?.joined(separator: ",") ?? "all")", message: message, action: .undo())
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        return await withCheckedContinuation { continuation in
            handle.onDismiss = { reason in continuation.resume(returning: reason != .action) }
        }
    }

    /// Runs one stash op; its failure reaches the page as the reason it shows.
    private func run(_ op: @escaping @MainActor () async throws -> Void) async throws {
        do { try await op() } catch { throw PageError.unavailable(RefusalStrings.describe(error)) }
    }

    private static func stashID(_ params: CmuxNextSettings.JSONValue) throws -> String {
        guard let id = params["stash"]?.stringValue, !id.isEmpty else { throw PageError.invalidParams("stash is required") }
        return id
    }

    private static func members(_ params: CmuxNextSettings.JSONValue) -> [String]? {
        params["members"]?.arrayValue?.compactMap(\.stringValue)
    }
}

/// The Undo toast's strings (table Stash.xcstrings); the page's own are webviews/src/pages/stash.
nonisolated enum StashPageStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "Stash", bundle: .module)
    }

    static var deletedTab: String { t("stash.deleted.tab", "Stashed tab deleted") }
    static var deletedGroup: String { t("stash.deleted.group", "Stashed group deleted") }
}
