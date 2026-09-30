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
    /// Whether this request writes or closes a terminal and must therefore be
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
             "mobile.terminal.mouse", "terminal.mouse",
             "mobile.terminal.close", "terminal.close":
            true
        default:
            false
        }
    }

    /// Whether the request writes to or closes a terminal. A phone must name
    /// that terminal: the Mac never falls back to its focused terminal, which
    /// would put a keystroke, paste, click or close into whatever terminal
    /// happens to be focused.
    var mustNameItsTerminal: Bool {
        isOrderedTerminalInput
            || method == "mobile.terminal.rename"
    }

    /// The per-surface ordering domain for an ordered terminal request.
    /// Requests without a surface selection share one conservative bucket.
    /// The key uses the same id precedence as terminal resolution and the
    /// canonical UUID spelling, so two spellings of one terminal never land
    /// in different buckets and overtake each other.
    var orderedInputSurfaceKey: String {
        Self.phoneNamedTerminalID(params: params)?.uuidString ?? ""
    }

    /// The terminal a phone request names, exactly as the phone stamped it.
    /// The ordering bucket, the explicit-terminal gate and the input ledger
    /// all read this one parser, so a request can never pass one and land
    /// differently in another.
    static func phoneNamedTerminalID(params: [String: Any]) -> UUID? {
        for key in ["surface_id", "terminal_id", "tab_id"] {
            guard let raw = params[key] as? String,
                  let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            return id
        }
        return nil
    }
}
