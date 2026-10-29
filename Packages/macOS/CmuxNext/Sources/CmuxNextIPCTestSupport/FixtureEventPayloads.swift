// `DaemonWireEvent` here is CmuxNextWireGen's EventEmitter output for
// cmux-tui/spec/fixtures/ipc-method-tables/sdk-schema.json, which CmuxNextWireGenPlugin writes into
// this target at build time; CmuxNextIPCTests' WireEventSetTests decodes with it. These are the
// payload types it names, the way TypeEmitter declares them. sdk-schema.json makes
// the `event` literal a required field of every event payload, so each type carries it, and a
// TYPED_EVENT payload holds it as its line does.
public nonisolated struct OutputEvent: Decodable, Equatable, Sendable {
    public let event: String
    public let surface: String
    public let seq: UInt64

    public init(surface: String, seq: UInt64) {
        event = "output"
        self.surface = surface
        self.seq = seq
    }
}

public nonisolated struct SizeStateEvent: Decodable, Equatable, Sendable {
    public let event: String
    public let surface: String
    public let cols: UInt16
    public let rows: UInt16

    public init(surface: String, cols: UInt16, rows: UInt16) {
        event = "size-state"
        self.surface = surface
        self.cols = cols
        self.rows = rows
    }
}

public nonisolated struct TabCreatedEvent: Decodable, Equatable, Sendable {
    public let event: String
    public let tab: String

    public init(tab: String) {
        event = "tab-created"
        self.tab = tab
    }
}

public nonisolated struct TabRenamedEvent: Decodable, Equatable, Sendable {
    public let event: String
    public let tab: String
    public let title: String

    public init(tab: String, title: String) {
        event = "tab-renamed"
        self.tab = tab
        self.title = title
    }
}
