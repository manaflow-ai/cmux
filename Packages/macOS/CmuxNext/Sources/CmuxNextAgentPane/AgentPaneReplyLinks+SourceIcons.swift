import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPaneReplyLinks {
    var sourceIconsEnabled: Bool { sourceIconsLayout ?? sourceIconsBaseline }

    func applySourceIconLayout(_ customization: AgentPaneCustomization) {
        sourceIconsLayout = nil
        if let text = customization.layoutJSON, let layout = try? JSONValue.parse(Data(text.utf8)),
           case .bool(let enabled) = layout["labs"]?["sourceIcons"] {
            sourceIconsLayout = enabled
        }
        if !sourceIconsEnabled { cancelSourceIcons() }
    }

    /// Passive icons require HTTPS; an HTTP source keeps its held icon or generic fallback.
    func faviconOrigin(_ url: URL) -> URL? {
        guard AgentPaneReplyRequest.webURL(url.absoluteString) != nil, GuardedRemoteFetch.allows(url),
              var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = "/favicon.ico"
        origin.query = nil
        origin.fragment = nil
        return origin.url
    }

    func loadSourceIcon(_ url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        // task-owner: this pane, until the source disappears, the lab turns off or the pane closes.
        let task = Task { await favicon(url) }
        sourceIconRequests[id] = (url, task)
        defer { sourceIconRequests[id] = nil }
        return await withTaskCancellationHandler {
            let data = await task.value
            return task.isCancelled || Task.isCancelled ? nil : data
        } onCancel: {
            task.cancel()
        }
    }

    func cancelSourceIcons(at url: URL? = nil) {
        for (id, request) in sourceIconRequests where url == nil || request.url == url {
            request.task.cancel()
            sourceIconRequests[id] = nil
        }
    }
}
