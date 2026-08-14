import CmuxTerminalCore
import Foundation

@MainActor
final class LinkTitleFetcher {
    static let shared = LinkTitleFetcher()
    private static let maximumBodyBytes = 65_536

    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    private init() {}

    func fetchTitleIfNeeded(for entry: WorkspaceCapturedLink, workspace: Workspace) async {
        guard LinksCaptureSettings.snapshot().fetchTitles,
              entry.fetchedTitle == nil,
              Self.mayFetchTitle(url: entry.url, hostKey: entry.hostKey),
              !inFlight.contains(entry.url),
              !failed.contains(entry.url) else {
            return
        }
        inFlight.insert(entry.url)
        defer { inFlight.remove(entry.url) }

        guard let url = URL(string: entry.url) else {
            failed.insert(entry.url)
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode) else {
                failed.insert(entry.url)
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
                failed.insert(entry.url)
                return
            }
            workspace.linksState.setFetchedTitle(title, for: entry.id)
        } catch {
            failed.insert(entry.url)
        }
    }

    static func mayFetchTitle(url: String, hostKey: String?) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard let hostKey else { return false }
        let host = CapturedLinkHostPolicy.hostPart(of: hostKey)
        return !CapturedLinkHostPolicy.isPrivateOrLocalHost(host)
    }

    static func extractTitle(from html: String) -> String? {
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
