import CmuxNextPages
import CmuxNextRemoteFetch
import CmuxNextSettings
import Foundation

extension AgentPaneReplyLinks {
    var sourceIconsEnabled: Bool { sourceIconsLayout ?? sourceIconsBaseline }

    func sourceIconReply(_ url: URL) async -> [String: Any] {
        guard sourceIconsEnabled else { return AgentPaneReply.success(["disabled": true]) }
        guard let icon = faviconOrigin(url) else { return AgentPaneReply.success() }
        let result = await loadSourceIcon(icon)
        if result == .temporary { return AgentPaneReply.success(["temporary": true]) }
        guard let png = result.png, png.count <= 64 << 10 else { return AgentPaneReply.success() }
        return AgentPaneReply.success(["icon": "data:image/png;base64," + png.base64EncodedString()])
    }

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

    func loadSourceIcon(_ url: URL) async -> AgentPaneSourceIconResult {
        guard !Task.isCancelled else { return .temporary }
        let id = UUID()
        // task-owner: this pane, until the source disappears, the lab turns off or the pane closes.
        let task = Task { await favicon(url) }
        sourceIconRequests[id] = (url, task)
        defer { sourceIconRequests[id] = nil }
        return await withTaskCancellationHandler {
            let data = await task.value
            return task.isCancelled || Task.isCancelled ? .temporary : data
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
