import Foundation

enum MenuBarProfilingProfilePreview {
    static let recipient = "founders@manaflow.com"

    static func text(outputURL: URL, email: String, summary: String) -> String {
        [
            String(format: String(localized: "statusMenu.profiling.previewRecipient", defaultValue: "Recipient: %@"), recipient),
            String(format: String(localized: "statusMenu.profiling.previewEmailFormat", defaultValue: "Your email: %@"), email),
            String(format: String(localized: "statusMenu.profiling.previewAttachmentFormat", defaultValue: "Attachment: %@"), outputURL.lastPathComponent + ".zip"),
            String(localized: "statusMenu.profiling.previewArchiveNote", defaultValue: "The email includes a zip with traces, logs, summary.md, and system-info.txt."),
            "",
            fileListText(for: outputURL),
            "",
            String(localized: "statusMenu.profiling.previewSummaryHeader", defaultValue: "summary.md preview:"),
            summary,
        ].joined(separator: "\n")
    }

    static func summaryText(for outputURL: URL) -> String {
        let summaryURL = outputURL.appendingPathComponent("summary.md")
        guard let summary = try? String(contentsOf: summaryURL, encoding: .utf8), !summary.isEmpty else {
            return String(localized: "statusMenu.profiling.summaryMissing", defaultValue: "summary.md is not available yet.")
        }
        return summary
    }

    static func submitArguments(profileURL: URL, replyToFile: URL, noteFile: URL, send: Bool = false) -> [String] {
        let summary = summaryText(for: profileURL)
        var args = [
            "--profile", profileURL.path,
            "--recipient", recipient,
            "--reply-to-file", replyToFile.path,
            "--note-file", noteFile.path,
            "--skip-dialog",
        ]
        if send {
            args.append("--send")
        }
        appendSummaryArgument("Name", as: "--target-name", from: summary, to: &args)
        appendSummaryArgument("PID", as: "--target-pid", from: summary, to: &args)
        appendSummaryArgument("Channel", as: "--channel", from: summary, to: &args)
        appendSummaryArgument("Bundle ID", as: "--bundle-id", from: summary, to: &args)
        return args
    }

    static func packageArguments(profileURL: URL) -> [String] {
        [
            "--profile", profileURL.path,
            "--package-only",
        ]
    }

    static func fileCount(for outputURL: URL) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return urls.count
    }

    private static func fileListText(for outputURL: URL) -> String {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: outputURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return String(localized: "statusMenu.profiling.filesUnavailable", defaultValue: "Files: unavailable")
        }

        let lines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            "- \(url.lastPathComponent) (\(displaySize(for: url)))"
        }
        if lines.isEmpty {
            return String(localized: "statusMenu.profiling.filesEmpty", defaultValue: "Files: none yet")
        }
        return String(localized: "statusMenu.profiling.filesHeader", defaultValue: "Files:") + "\n" + lines.joined(separator: "\n")
    }

    private static func displaySize(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            return String(localized: "statusMenu.profiling.folderSize", defaultValue: "folder")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
    }

    private static func appendSummaryArgument(_ label: String, as option: String, from summary: String, to args: inout [String]) {
        guard let value = summaryValue(label, in: summary) else { return }
        args.append(contentsOf: [option, value])
    }

    private static func summaryValue(_ label: String, in summary: String) -> String? {
        let prefix = "- \(label): "
        return summary
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
