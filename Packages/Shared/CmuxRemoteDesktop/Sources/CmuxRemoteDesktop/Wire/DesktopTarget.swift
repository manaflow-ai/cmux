public import CmuxMobileWire
import CmuxBrowserStream

/// What the phone asks to see (`channel.open.params.target`).
public enum DesktopTarget: Hashable, Sendable {
    /// One of the Mac's displays; nil means the main display.
    case display(UInt32?)
    /// One on-screen window of the Mac's console user.
    case window(UInt32)
    /// A VNC server the Mac can reach.
    case vnc(VncAddress)

    public var kind: DesktopTargetKind {
        switch self {
        case .display: .display
        case .window: .window
        case .vnc: .vnc
        }
    }

    public var jsonValue: JSONValue {
        var out: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        switch self {
        case .display(let id): if let id { out["display"] = .int(Int64(id)) }
        case .window(let id): out["window"] = .int(Int64(id))
        case .vnc(let address): out.merge(address.jsonMembers) { $1 }
        }
        return .object(out)
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try DesktopJSON(json)
        switch try r.string("kind") {
        case DesktopTargetKind.display.rawValue:
            self = .display(r.has("display") ? try r.uint32("display") : nil)
        case DesktopTargetKind.window.rawValue:
            self = .window(try r.uint32("window"))
        case DesktopTargetKind.vnc.rawValue:
            let port = r.has("port") ? try r.int("port", in: 0...Int64(UInt16.max)) : VncAddress.defaultPort
            self = .vnc(try VncAddress(host: try r.string("host"), port: port, name: r.optionalString("name")))
        case let other:
            throw RdWireError("target kind \(other)")
        }
    }
}
