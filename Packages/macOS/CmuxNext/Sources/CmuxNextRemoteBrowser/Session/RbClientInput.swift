public import CmuxNextRemoteView
import Foundation

#if DEBUG
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
