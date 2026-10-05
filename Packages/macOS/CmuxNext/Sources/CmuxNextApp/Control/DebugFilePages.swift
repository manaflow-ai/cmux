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
        return .object(result)
    }
}
#endif
