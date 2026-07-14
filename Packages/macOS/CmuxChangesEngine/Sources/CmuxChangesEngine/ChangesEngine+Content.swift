import CryptoKit
import Foundation

extension ChangesEngine {
    func contentIsBinary(_ data: Data) -> Bool {
        data.prefix(8_000).contains(0)
    }

    func textLines(_ text: String) -> (lines: [String], hasTrailingNewline: Bool) {
        guard !text.isEmpty else { return ([], false) }
        let hasTrailingNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasTrailingNewline {
            lines.removeLast()
        }
        return (lines, hasTrailingNewline)
    }

    func untrackedPatch(path: String, data: Data, isBinary: Bool) throws -> String {
        let header = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        if isBinary {
            return header + "Binary file SHA256 \(sha256Hex(data))\n"
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChangesEngineError.unreadableText(path)
        }
        let content = textLines(text)
        guard !content.lines.isEmpty else { return header }
        var parts = [header, "@@ -0,0 +1,\(content.lines.count) @@\n"]
        parts.reserveCapacity(content.lines.count + 3)
        parts.append(contentsOf: content.lines.map { "+\($0)\n" })
        if !content.hasTrailingNewline {
            parts.append("\\ No newline at end of file\n")
        }
        return parts.joined()
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isLarge(additions: Int, deletions: Int, patchBytes: Int) -> Bool {
        additions + deletions > Self.largeLineThreshold || patchBytes > Self.largePatchByteThreshold
    }
}
