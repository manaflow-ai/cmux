public import CmuxMobileWire
import CmuxBrowserStream

/// One on-screen window offered by `desktop.windows`.
public struct DesktopWindow: Hashable, Sendable, Identifiable {
    public var id: UInt32
    public var app: String
    public var title: String

    public init(id: UInt32, app: String, title: String) {
        self.id = id
        self.app = app
        self.title = title
    }

    public var jsonValue: JSONValue {
        .object(["id": .int(Int64(id)), "app": .string(app), "title": .string(title)])
    }

    public init(json: JSONValue) throws(RdWireError) {
        let r = try DesktopJSON(json)
        id = try r.uint32("id")
        app = try r.string("app")
        title = try r.string("title")
    }
}
