import CmuxAgentChat
import Foundation

extension ChatArtifactViewerRouteView {
    func progressValue(fetched: Int64, total: Int64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return Double(fetched) / Double(total)
    }

    func progressText(fetched: Int64, total: Int64?) -> String {
        if let total {
            return "\(formattedSize(fetched)) / \(formattedSize(total))"
        }
        return formattedSize(fetched)
    }

    func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func tooLargeMessage(actualSize: Int64?, limit: Int64) -> String {
        guard let actualSize else {
            let format = String(
                localized: "chat.artifact.too_large.limit_message",
                defaultValue: "This preview is limited to %@.",
                bundle: .module
            )
            return String.localizedStringWithFormat(format, formattedSize(limit))
        }
        let format = String(
            localized: "chat.artifact.too_large.message",
            defaultValue: "This file is %@; previews are limited to %@.",
            bundle: .module
        )
        return String.localizedStringWithFormat(
            format,
            formattedSize(actualSize),
            formattedSize(limit)
        )
    }
}

extension ChatArtifactStat {
    /// Whether this artifact routes to the recursive folder browser.
    func showsFolder(supportsDirectoryBrowsing: Bool) -> Bool {
        isDirectory && supportsDirectoryBrowsing
    }
}
