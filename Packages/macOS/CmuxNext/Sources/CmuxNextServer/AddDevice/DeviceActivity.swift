public import Foundation

/// One line of the device audit (`cmux device audit --json`): an add, an invite, a remove, or an
/// admission decision of remote hosting.
public nonisolated struct DeviceActivity: Equatable, Sendable, Decodable {
    /// RFC 3339 time.
    public var ts: String
    /// `device.added`, `device.removed`, `device.invited`, … ; nil for an admission line.
    public var event: String?
    /// The admission decision (`allow`, `deny`, `revoke`) when it is not a device event.
    public var decision: String?
    public var name: String?
    public var device: String?
    public var login: String?

    public init(ts: String, event: String?, decision: String? = nil, name: String? = nil, device: String? = nil, login: String? = nil) {
        self.ts = ts
        self.event = event
        self.decision = decision
        self.name = name
        self.device = device
        self.login = login
    }

    /// Who or what the line is about, as a person reads it.
    public var subject: String {
        if let name { return name }
        if let device { return device.split(separator: ":", maxSplits: 1).last.map(String.init) ?? device }
        return login ?? ""
    }

    nonisolated struct Page: Decodable {
        var entries: [DeviceActivity]
    }

    /// The entries of `cmux device audit --json`, newest first.
    public static func parse(_ data: Data) throws -> [DeviceActivity] {
        try JSONDecoder().decode(Page.self, from: data).entries
    }
}
