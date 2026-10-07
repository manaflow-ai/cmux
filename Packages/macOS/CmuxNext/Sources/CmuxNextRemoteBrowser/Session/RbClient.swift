import CCmuxRdFFI
public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// Why the client reducer refused a call.
public nonisolated enum RbClientError: Error, Sendable, Hashable {
    /// The input is not a client input (the state did not change).
    case invalid
    /// The reducer panicked; this client is unusable.
    case poisoned
    /// The outcome was not the documented JSON shape.
    case malformedOutcome
    case code(Int32)
}

/// The viewer's reducer of one remote tab (`cmux.rb/1`), implemented by the
/// shared Rust core (cmux-rd-ffi `CmuxRbClient` over
/// cmux-remote-browser `client::Client`). Host messages and the person's
/// answers go in; effects (native menus, sheets, cursor, page state,
/// messages for the host) come out. JSON in the shapes of
/// schemas/remote-tab/client.json. No I/O; not thread-safe: one actor owns
/// an instance.
public nonisolated final class RbClient {
    private let handle: OpaquePointer

    /// Nil only when the core cannot allocate a client.
    public init?() {
        // The rb client C ABI exists from ABI 2 on; an older static library
        // would fail to link, so this only guards a mismatched header.
        assert(RemoteRdCore.abiVersion >= 2, "CCmuxAppFFI predates the rb client ABI (needs ABI 2)")
        guard let handle = cmux_rb_client_new() else { return nil }
        self.handle = handle
    }

    deinit {
        cmux_rb_client_free(handle)
    }

    /// Applies one input and returns its outcome. A refused input
    /// (`outcome.reject`) leaves the state unchanged.
    public func apply(_ input: RbClientInput) throws(RbClientError) -> RbClientOutcome {
        guard let json = try? JSONEncoder().encode(input.json) else { throw .invalid }
        var outcome: UnsafePointer<UInt8>?
        var length = 0
        let code = json.withUnsafeBytes { raw in
            cmux_rb_client_apply(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, &outcome, &length)
        }
        switch code {
        case 0: break
        case -2: throw .invalid
        case -6: throw .poisoned
        default: throw .code(code)
        }
        guard let outcome else { throw .malformedOutcome }
        let bytes = Data(bytes: outcome, count: length)
        guard let decoded = try? Self.decoder.decode(RbClientOutcome.self, from: bytes) else { throw .malformedOutcome }
        return decoded
    }

    /// Plain keys: `send` bodies are host messages and keep their names.
    private static let decoder = JSONDecoder()
}

/// One input to the client reducer (`ClientInput`, tag `op`).
public nonisolated enum RbClientInput: Sendable, Equatable {
    /// A control body from the host (an `rb.*` message).
    case host(RemoteRdJSON)
    case menuChosen(token: UInt64, choice: RbMenuChoice)
    case dialogAnswered(token: UInt64, accept: Bool, text: String?)
    case resize(RbScreen)
    case navigate(String)
    case tabOpened(request: UInt64, tab: String?, refused: String?)

    var json: RemoteRdJSON {
        switch self {
        case let .host(message):
            .object(["op": .string("host"), "message": message])
        case let .menuChosen(token, choice):
            .object(["op": .string("menu_chosen"), "token": .int(Int64(clamping: token)), "choice": choice.json])
        case let .dialogAnswered(token, accept, text):
            .object(["op": .string("dialog_answered"), "token": .int(Int64(clamping: token)), "accept": .bool(accept), "text": text.map { .string($0) } ?? .null])
        case let .resize(screen):
            .object(["op": .string("resize"), "screen": screen.json])
        case let .navigate(url):
            .object(["op": .string("navigate"), "url": .string(url)])
        case let .tabOpened(request, tab, refused):
            .object([
                "op": .string("tab_opened"), "request": .int(Int64(clamping: request)),
                "tab": tab.map { .string($0) } ?? .null, "refused": refused.map { .string($0) } ?? .null,
            ])
        }
    }
}

/// The person's answer to a menu.
public nonisolated enum RbMenuChoice: Sendable, Hashable {
    case cancel
    /// A context menu command id.
    case command(Int64)
    /// `<select>` option indices.
    case indices([UInt32])

    var json: RemoteRdJSON {
        switch self {
        case .cancel: .object(["choice": .string("cancel")])
        case let .command(id): .object(["choice": .string("command"), "id": .int(id)])
        case let .indices(indices): .object(["choice": .string("indices"), "indices": .array(indices.map { .int(Int64($0)) })])
        }
    }
}

/// The pane and its screen (`ScreenInfo`).
public nonisolated struct RbScreen: Sendable, Hashable {
    public var cssWidth: Int
    public var cssHeight: Int
    public var scale: Double
    public var refreshHz: Int
    public var colorSpace: String

    public init(viewport: RemoteBrowserViewport, refreshHz: Int = 60, colorSpace: String = "srgb") {
        cssWidth = viewport.cssWidth
        cssHeight = viewport.cssHeight
        scale = Double(viewport.scale)
        self.refreshHz = refreshHz
        self.colorSpace = colorSpace
    }

    var json: RemoteRdJSON {
        .object([
            "css_width": .int(Int64(cssWidth)), "css_height": .int(Int64(cssHeight)), "scale": .double(scale),
            "refresh_hz": .int(Int64(refreshHz)), "color_space": .string(colorSpace),
        ])
    }
}
#endif
