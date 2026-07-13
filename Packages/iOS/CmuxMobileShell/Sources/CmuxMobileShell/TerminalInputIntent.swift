import Foundation

enum TerminalInputIntent: Sendable {
    case text(String, workspaceID: String)
    case paste(String, submitKey: String, workspaceID: String)
    case image(Data, format: String, workspaceID: String)
    case fence

    var bufferedByteCount: Int {
        switch self {
        case .text(let text, _):
            text.utf8.count
        case .paste(let text, let submitKey, _):
            text.utf8.count + submitKey.utf8.count
        case .image(let data, let format, _):
            data.count + format.utf8.count
        case .fence:
            0
        }
    }
}

enum TerminalRPCDeadlinePolicy {
    case interaction
    case input

    var timeoutNanoseconds: UInt64? {
        switch self {
        case .interaction:
            TerminalScrollSession.interactionRPCDeadlineNanoseconds
        case .input:
            // `nil` delegates to the client's normal runtime RPC deadline.
            nil
        }
    }
}
