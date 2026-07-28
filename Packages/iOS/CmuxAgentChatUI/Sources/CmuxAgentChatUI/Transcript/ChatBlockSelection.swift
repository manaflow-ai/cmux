enum ChatBlockSelection: Identifiable, Equatable {
    case message(id: String)
    case terminalCommand(id: Int)
    case codeBlock(messageID: String, segmentIndex: Int)

    var id: String {
        switch self {
        case .message(let id):
            return "msg-\(id)"
        case .terminalCommand(let id):
            return "term-\(id)"
        case .codeBlock(let messageID, let segmentIndex):
            return "code-\(messageID)-\(segmentIndex)"
        }
    }
}
