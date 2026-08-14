import CmuxTerminalCore
import Foundation

@MainActor
final class LinkTitleFetcher {
    static let shared = LinkTitleFetcher()
    private static let maximumBodyBytes = 65_536

    private struct FetchKey: Hashable {
        let workspaceId: UUID
        let url: String
    }

    private var inFlight: Set<FetchKey> = []
    private var failed: Set<FetchKey> = []

    private init() {}

    func fetchTitleIfNeeded(for entry: WorkspaceCapturedLink, workspace: Workspace) async {
        let key = FetchKey(workspaceId: workspace.id, url: entry.url)
        guard LinksCaptureSettings.snapshot().fetchTitles,
              entry.fetchedTitle == nil,
              Self.mayFetchTitle(url: entry.url, hostKey: entry.hostKey),
              !inFlight.contains(key),
              !failed.contains(key) else {
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        guard let url = URL(string: entry.url) else {
            failed.insert(key)
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let redirectDelegate = LinkTitleRedirectDelegate()
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request,
                delegate: redirectDelegate
            )
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode),
                  Self.allowsFetchResponseURL(httpResponse.url) else {
                failed.insert(key)
                return
            }

            var data = Data()
            data.reserveCapacity(Self.maximumBodyBytes)
            for try await byte in bytes {
                if data.count == Self.maximumBodyBytes {
                    bytes.task.cancel()
                    break
                }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8),
                  let title = Self.extractTitle(from: html),
                  !title.isEmpty else {
                failed.insert(key)
                return
            }
            workspace.linksState.setFetchedTitle(title, for: entry.id)
        } catch {
            failed.insert(key)
        }
    }

    nonisolated static func mayFetchTitle(url: String, hostKey: String?) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard let hostKey else { return false }
        let host = CapturedLinkHostPolicy.hostPart(of: hostKey)
        return !CapturedLinkHostPolicy.isPrivateOrLocalHost(host)
    }

    nonisolated static func allowsRedirect(to url: URL?) -> Bool {
        allowsFetchResponseURL(url)
    }

    nonisolated private static func allowsFetchResponseURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let hostKey = CapturedLinkHostPolicy.hostKey(for: url.absoluteString) else {
            return false
        }
        let host = CapturedLinkHostPolicy.hostPart(of: hostKey)
        return !CapturedLinkHostPolicy.isPrivateOrLocalHost(host)
    }

    nonisolated static func extractTitle(from html: String) -> String? {
        guard let openRange = html.range(of: "<title", options: [.caseInsensitive]),
              let closeOfOpen = html[openRange.upperBound...].firstIndex(of: ">"),
              let closeRange = html.range(
                of: "</title>",
                options: [.caseInsensitive],
                range: closeOfOpen..<html.endIndex
              ) else {
            return nil
        }
        let raw = html[html.index(after: closeOfOpen)..<closeRange.lowerBound]
        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LinkTitleRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(LinkTitleFetcher.allowsRedirect(to: request.url) ? request : nil)
    }
}
