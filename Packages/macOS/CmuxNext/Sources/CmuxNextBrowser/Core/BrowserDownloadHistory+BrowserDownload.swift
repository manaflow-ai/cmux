import Foundation

extension BrowserDownloadHistory.Row {
    /// `item` as kept; nil while it runs.
    package init?(_ item: BrowserDownload) {
        let (status, reason): (String, String?) = switch item.status {
        case .inProgress: ("", nil)
        case .finished: ("finished", nil)
        case .failed(let why): ("failed", why)
        case .cancelled: ("cancelled", nil)
        case .blocked(let why): ("blocked", why)
        }
        guard !status.isEmpty else { return nil }
        // Only a web link is kept: a data: or blob: source can be megabytes.
        let source = item.sourceURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0.absoluteString : nil }
        self.init(filename: item.filename, source: source,
                  destination: item.destination?.path(percentEncoded: false), status: status, reason: reason,
                  received: item.receivedBytes, total: item.totalBytes)
    }

    /// The list's row for this kept download; nil for one this build cannot read.
    package var download: BrowserDownload? {
        let ended: BrowserDownload.Status
        switch status {
        case "finished": ended = .finished
        case "failed": ended = .failed(reason ?? "")
        case "cancelled": ended = .cancelled
        case "blocked": ended = .blocked(reason ?? "")
        default: return nil
        }
        return .ended(sourceURL: source.flatMap(URL.init(string:)), filename: filename,
                      destination: destination.map { URL(filePath: $0) }, status: ended,
                      receivedBytes: received, totalBytes: total)
    }
}
