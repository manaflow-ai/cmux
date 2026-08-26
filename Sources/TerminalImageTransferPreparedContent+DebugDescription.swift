#if DEBUG
extension TerminalImageTransferPreparedContent {
    var cmuxDebugDescription: String {
        switch self {
        case .insertText(let text):
            return "insertText(length:\(text.utf8.count),hasNewlines:\(text.contains(where: \.isNewline) ? 1 : 0))"
        case .fileURLs(let fileURLs):
            return "fileURLs(count:\(fileURLs.count))"
        case .reject:
            return "reject"
        }
    }
}
#endif
