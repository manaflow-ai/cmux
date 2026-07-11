import Foundation

enum BridgeProtocol {
    static let version = 1
    static let slotCount = 3
}

struct BridgeEvent: Codable, Sendable {
    let type: String
    var version: Int?
    var sharedMemoryPath: String?
    var slotCount: Int?
    var slotSize: Int?
    var slot: Int?
    var sequence: UInt32?
    var timestampMicroseconds: UInt64?
    var width: Int?
    var height: Int?
    var bytesPerRow: Int?
    var bottomUp: Bool?
    var message: String?

    init(
        type: String,
        version: Int? = nil,
        sharedMemoryPath: String? = nil,
        slotCount: Int? = nil,
        slotSize: Int? = nil,
        slot: Int? = nil,
        sequence: UInt32? = nil,
        timestampMicroseconds: UInt64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bytesPerRow: Int? = nil,
        bottomUp: Bool? = false,
        message: String? = nil
    ) {
        self.type = type
        self.version = version
        self.sharedMemoryPath = sharedMemoryPath
        self.slotCount = slotCount
        self.slotSize = slotSize
        self.slot = slot
        self.sequence = sequence
        self.timestampMicroseconds = timestampMicroseconds
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bottomUp = bottomUp
        self.message = message
    }
}

struct BridgeCommand: Codable, Sendable {
    let type: String
    var slot: Int?
    var x: Int?
    var y: Int?
    var phase: String?
    var text: String?
    var key: String?
}

actor BridgeEventWriter {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func send(_ event: BridgeEvent) throws {
        var data = try encoder.encode(event)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}
