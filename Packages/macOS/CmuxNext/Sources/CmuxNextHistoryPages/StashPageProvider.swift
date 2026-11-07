public import AppKit
import CmuxNextDaemonService
import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings
public import CmuxNextStash
import Foundation

/// The Stashed Tabs page's `cmux.stash.*` (webviews/src/pages/stash). The daemon owns the stashes:
/// `stash.list`, `stash.import` (with the app's browser engine added) and the `stash-changed`
/// stream go through the page relay. Two ops stay in the app, as native glue:
///
/// - `cmux.stash.restore {stash, members?, new_workspace?}`: only the app knows the pane a page
///   reopens in and shows what came back.
/// - `cmux.stash.delete {stash, members?}`: on the person's click, the page's members hide while
///   the app's Undo toast is up. Each delete spends its click: a second delete off the same
///   gesture is refused. The delete goes to the daemon only when the toast's time runs out;
///   Undo, a newer toast in its place, closing it, the page closing or the call's cancel all
///   keep the stash. Answers `{deleted}` then (false: kept).
@MainActor
public final class StashPageProvider: PageProvider {
    /// Shows the Undo toast and reports how it ended; answers the toast's dismiss, or nil when
    /// no window shows it (the delete is then kept). Tests replace it.
    typealias PresentUndo = @MainActor (CmuxToast, _ ended: @escaping @MainActor (CmuxToastDismissReason) -> Void) -> (() -> Void)?

    private let restore: @MainActor (String, [String]?, Bool) async throws -> Void
    private let commitDelete: @MainActor (String, [String]?) async throws -> Void
    private let importEngine: @MainActor () -> String
    private let relay: any PageProvider
    /// The gesture (its event's uptime) the last delete spent.
    private var spentGesture: TimeInterval?
    /// The Undo toasts up now; the page's close keeps every one's stash.
    private var pending: [ObjectIdentifier: PendingUndo] = [:]
    /// The page view whose window shows the Undo toast.
    public var anchor: () -> NSView? = { nil }
    var presentUndo: PresentUndo

    /// The Stashed Tabs top page's title.
    public static var title: String { StashPageStrings.title }

    public convenience init(stash: StashService, relay: any PageProvider) {
        self.init(restore: { id, members, newWorkspace in try await stash.restore(id, members: members, inNewWorkspace: newWorkspace) },
                  delete: { id, members in try await stash.delete(id, members: members) },
                  importEngine: { stash.importEngine }, relay: relay)
    }

    init(restore: @escaping @MainActor (String, [String]?, Bool) async throws -> Void,
         delete: @escaping @MainActor (String, [String]?) async throws -> Void,
         importEngine: @escaping @MainActor () -> String, relay: any PageProvider) {
        self.restore = restore
        commitDelete = delete
        self.importEngine = importEngine
        self.relay = relay
        presentUndo = { _, _ in nil }
        presentUndo = { [weak self] toast, ended in
            guard let window = self?.anchor()?.window else { return nil }
            let handle = CmuxToastCenter.shared.show(toast, in: window)
            handle.onDismiss = { ended($0) }
            return { handle.dismiss() }
        }
    }

    public func call(_ op: String, params: CmuxNextSettings.JSONValue, context: PageCallContext) async throws -> CmuxNextSettings.JSONValue {
        switch op {
        case "cmux.stash.restore":
            let id = try Self.stashID(params)
            let members = Self.members(params), newWorkspace = params["new_workspace"]?.boolValue == true
            try await run { try await self.restore(id, members, newWorkspace) }
            return ["restored": true]
        case "cmux.stash.delete":
            let id = try Self.stashID(params)
            guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
            }
            spentGesture = event
            let members = Self.members(params)
            guard await undoToast(id: id, members: members), !Task.isCancelled else { return ["deleted": false] }
            try await run { try await self.commitDelete(id, members) }
            return ["deleted": true]
        case "cmux.stash.import":
            var members = params.objectValue ?? [:]
            members["engine"] = .string(importEngine())
            return try await relay.call(op, params: .object(members), context: context)
        default:
            return try await relay.call(op, params: params, context: context)
        }
    }

    public func subscribe(_ stream: String, filter: CmuxNextSettings.JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (CmuxNextSettings.JSONValue) -> Void) async throws -> PageSubscription {
        try await relay.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
    }

    public func pageDidClose() {
        let open = pending.values
        pending.removeAll()
        for undo in open { undo.keep() }
    }

    /// "Stashed tab deleted" (or group) with Undo in the page's window; true only when its time
    /// ran out. Resolves once: Undo, a replacement, a close, the page's close and a cancel keep it.
    private func undoToast(id: String, members: [String]?) async -> Bool {
        let message = members == nil ? StashPageStrings.deletedGroup : StashPageStrings.deletedTab
        let toast = CmuxToast(id: "stash.delete.\(id).\(members?.joined(separator: ",") ?? "all")", message: message, action: .undo())
        let undo = PendingUndo()
        let key = ObjectIdentifier(undo)
        defer { pending[key] = nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                undo.continuation = continuation
                guard !Task.isCancelled else { return undo.keep() }
                pending[key] = undo
                guard let dismiss = presentUndo(toast, { [weak undo] reason in undo?.ended(reason) }) else { return undo.keep() }
                undo.dismiss = dismiss
            }
        } onCancel: {
            Task { @MainActor in undo.keep() }
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

/// One delete's Undo toast: resumes its call once, with true only for a commit.
@MainActor
private final class PendingUndo {
    var continuation: CheckedContinuation<Bool, Never>?
    var dismiss: (() -> Void)?

    func resolve(_ commit: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: commit)
        if !commit, let dismiss {
            self.dismiss = nil
            dismiss()
        }
    }

    /// Keeps the stash and takes the toast down.
    func keep() { resolve(false) }

    /// The toast ended on its own: only its time running out commits (Undo, a newer toast in its
    /// place and its close keep the stash).
    func ended(_ reason: CmuxToastDismissReason) {
        dismiss = nil
        resolve(reason == .timeout)
    }
}

/// The top page's title and the Undo toast's strings (this target's Localizable.xcstrings); the
/// page's own are webviews/src/pages/stash.
nonisolated enum StashPageStrings {
    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static var title: String { t("stash.title", "Stashed Tabs") }
    static var deletedTab: String { t("stash.deleted.tab", "Stashed tab deleted") }
    static var deletedGroup: String { t("stash.deleted.group", "Stashed group deleted") }
}
