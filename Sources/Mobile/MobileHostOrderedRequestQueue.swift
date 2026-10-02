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
    /// Whether this request can write terminal input and must therefore be
    /// handled in arrival order rather than on a concurrent response task.
    /// paste_image belongs here because its handler writes the materialized
    /// image path into the PTY; scroll and mouse belong here because their
    /// handlers emit mouse-report bytes when the terminal has mouse reporting
    /// active, and either could otherwise overtake earlier queued keystrokes.
    var isOrderedTerminalInput: Bool {
        switch method {
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.mouse", "terminal.mouse":
            true
        default:
            false
        }
    }

    /// The per-surface ordering domain for an ordered terminal request.
    /// Requests without a surface selection share one conservative bucket.
    var orderedInputSurfaceKey: String {
        (params["surface_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
