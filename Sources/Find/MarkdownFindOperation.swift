/// A single DOM-find operation performed by ``MarkdownFindController``.
enum MarkdownFindOperation {
    case search(String)
    case next
    case previous
    case clear
}
