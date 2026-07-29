import Foundation

struct MobileHostOrderedRequest: Sendable {
    let frameByteCount: Int
    let decodedRequest: Result<MobileHostRPCRequest, MobileHostRPCError>
}

struct MobileHostOrderedRequestQueue {
    private var requests: [MobileHostOrderedRequest] = []

    var isEmpty: Bool { requests.isEmpty }
    var frameByteCounts: [Int] { requests.map(\.frameByteCount) }

    mutating func enqueue(_ request: MobileHostOrderedRequest) {
        requests.append(request)
    }

    mutating func dequeue() -> MobileHostOrderedRequest? {
        guard !requests.isEmpty else { return nil }
        return requests.removeFirst()
    }

    mutating func removeAll() {
        requests.removeAll()
    }
}

extension MobileHostRPCRequest {
    /// Whether this request writes terminal input and must therefore be
    /// handled in arrival order rather than on a concurrent response task.
    /// paste_image belongs here too: its handler writes the materialized
    /// image path into the PTY, so running it concurrently could inject that
    /// path ahead of earlier queued keystrokes.
    var isOrderedTerminalInput: Bool {
        switch method {
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image":
            true
        default:
            false
        }
    }
}
