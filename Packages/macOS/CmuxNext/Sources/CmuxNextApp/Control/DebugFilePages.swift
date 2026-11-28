import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings

#if DEBUG
/// `debug.filepages`: the file pages for live checks (diff-host S6, S7, R96). `{}` reports every
/// file page tab (its file and whether it has a page), the recovery drafts on disk and the toasts
/// of every window. `{restore: <draft id>}` runs the launch notice's Open for that draft (the
/// same `RecoveryDraftStore.restoreHandler`). `{open_link: {key, href, target}}` sends tab `key`'s
/// provider the markdown page's `openLink` (kind file) as that page would, with the page's real
/// user gesture; it returns at once (a sheet may wait for a press) and `{}` then reports
/// `last_open_link` ("opened", or the refusal's code). Note: the context carries the page's real
/// gesture of the last second, so in DEBUG a socket caller that acts within 1 s of a person's
/// real click or key in that page can raise the open-outside sheet (the sheet still needs a press). `{crash_page: key}` ends that tab's
/// WebContent process.
@MainActor
enum DebugFilePages {
    private static var lastOpenLink: String?

    static func run(_ params: [String: JSONValue], _ services: AppServices) async -> JSONValue {
        let drafts = await RecoveryDraftStore.shared.drafts()
        var result: [String: JSONValue] = [:]
        if let id = params["restore"]?.stringValue {
            guard let draft = drafts.first(where: { $0.id == id }), let handler = RecoveryDraftStore.shared.restoreHandler else {
                return ["restored": false]
            }
            handler(draft)
            result["restored"] = true
        }
        if case .object(let link)? = params["open_link"], let key = link["key"]?.stringValue,
           let provider = services.viewers.markdownPages.provider(key), let file = provider.file,
           let page = services.viewers.markdownPages.pageView(key) {
            let call: JSONValue = ["path": .string(file.path), "href": link["href"] ?? "", "kind": "file", "target": link["target"] ?? ""]
            let context = PageCallContext(page: page.descriptor.id, userGesture: page.debugHasRecentUserGesture)
            result["gesture"] = .bool(context.userGesture)
            lastOpenLink = "pending"
            // task-owner: one debug link call; it ends with the sheet's answer or the refusal
            Task { @MainActor in
                do {
                    _ = try await provider.call(provider.kind.op("openLink"), params: call, context: context)
                    lastOpenLink = "opened"
                } catch let error as PageError {
                    lastOpenLink = error.code
                } catch {
                    lastOpenLink = "failed"
                }
            }
        }
        if let key = params["crash_page"]?.stringValue {
            let page = services.viewers.editorPages.pageView(key) ?? services.viewers.markdownPages.pageView(key)
            result["crashed"] = .bool(page?.debugKillWebContent() ?? false)
        }
        result["last_open_link"] = lastOpenLink.map { .string($0) } ?? .null
        result["tabs"] = .array([services.viewers.markdownPages, services.viewers.editorPages].flatMap { service in
            service.debugTabs.map { tab in
                JSONValue.object(["key": .string(tab.key), "kind": .string(service.kind.namespace),
                                  "file": tab.file.map { .string($0.path) } ?? .null,
                                  "has_page": .bool(tab.page != nil)])
            }
        })
        result["drafts"] = .array(drafts.map { draft in
            .object(["id": .string(draft.id), "title": .string(draft.title), "bytes": .number(Double(draft.contents.count)),
                     "base": draft.base?.contentHash.map { .string($0) } ?? .null])
        })
        let windows = services.windows.controllers.compactMap(\.window)
        result["toasts"] = .array(windows.flatMap { CmuxToastCenter.shared.toasts(in: $0) }.map { .string($0.message) })
        // Undo toast of closes (REOPEN-CLOSED): why a close showed no toast (nxdog47).
        result["undo"] = services.closedTabs.map { tracker -> JSONValue in
            let undo = tracker.undoToasts
            return .object([
                "announced": .number(Double(undo.announced)), "announced_without_tabs": .number(Double(undo.announcedEmpty)),
                "waiting": .array(undo.waiting.map { .object(["pane": $0.pane.map(JSONValue.string) ?? .null, "tabs": .number(Double($0.tabs)),
                                                             "records": .number(Double($0.records)), "daemon_tabs": .number(Double($0.daemonTabs))]) }),
                // Whether the closed history reaches the app at all (nxdog48: closed_items stayed empty).
                "daemons": .array(services.machines.daemons.map { daemon in
                    .object(["machine": .string(daemon.machineID), "serves_state": .bool(daemon.store.servesStateResources),
                             "session_known": .bool(daemon.store.session.known), "mirror": .bool(daemon.store.session.mirror != nil),
                             "closed": .number(Double(daemon.store.closedItems.count)),
                             "newest_closed": daemon.store.closedItems.first.map { .string($0.id) } ?? .null])
                }),
                "last_reopen": undo.lastReopen.map { reopen -> JSONValue in
                    func ms(_ duration: Duration?) -> JSONValue {
                        duration.map { .number(Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15) } ?? .null
                    }
                    return .object(["id": .string(reopen.id), "tabs": .array(reopen.tabs.map(JSONValue.string)), "reply_ms": ms(reopen.reply),
                                    "applied_ms": ms(reopen.applied), "tabs_in_store_at_applied": reopen.tabsInStoreAtApplied.map(JSONValue.bool) ?? .null,
                                    "tabs_arrived_ms": ms(reopen.tabsArrived)])
                } ?? .null,
                "closed_items": .array(undo.recentDaemonItems.map { .object(["id": .string($0.id), "pane": $0.pane.map(JSONValue.string) ?? .null,
                                                                            "tabs": .number(Double($0.tabs)), "matched": .bool($0.matched)]) }),
            ])
        } ?? .null
        return .object(result)
    }
}
#endif
