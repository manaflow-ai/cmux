#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// One message of the control channel to the Chromium host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1). The C++ side is
/// `ChromiumHost/src/chromium_host_control.h`, which lists the frame layout;
/// both sides check the same golden frame (`ChromiumHostControlChannelTests`,
/// `chromium_host_control_test.cpp`).
///
/// A bytes or str field too large for the frame (``sharedFieldIndices()``)
/// goes in a ``ChromiumHostSharedRegion`` (task 020): the frame carries a
/// shared field (wire type 6 or 7, the u64 byte count) and the region is one
/// of the frame's last descriptors, in field order. ``decode(_:fds:)`` reads
/// and closes the regions, so a received message holds ordinary fields and
/// only the sender's own descriptors.
nonisolated struct ChromiumHostControlMessage: Equatable, Sendable {
    /// A field's value; the case is its wire type.
    enum Value: Equatable, Sendable {
        case i32(Int32)
        case i64(Int64)
        case f64(Double)
        case bytes([UInt8])
        case str(String)
    }

    struct Field: Equatable, Sendable {
        var tag: UInt8
        var value: Value
    }

    static let headerSize = 12
    static let fieldHeaderSize = 4
    /// Larger payloads go as a sealed shm descriptor (task 020).
    static let maxBody = 64 * 1024
    static let maxFds = 4
    static let fdCountMask: UInt16 = 0x0007
    static let replyFlag: UInt16 = 0x0008
    static let knownFlags: UInt16 = fdCountMask | replyFlag
    /// Wire types of a payload in a shared region; never a ``Value``.
    static let sharedBytesType: UInt8 = 6
    static let sharedStrType: UInt8 = 7
    /// A shared field's value: the u64 byte count.
    static let sharedFieldSize = 8

    var op: UInt16
    /// The message answers ``token``.
    var isReply: Bool
    var token: UInt32
    var fields: [Field]
    /// Sent: the caller's descriptors (the channel sends duplicates and the
    /// caller keeps its own). Received: descriptors the receiver owns and closes.
    var fds: [Int32]

    init(op: UInt16, token: UInt32 = 0, isReply: Bool = false, fields: [Field] = [], fds: [Int32] = []) {
        self.op = op
        self.token = token
        self.isReply = isReply
        self.fields = fields
        self.fds = fds
    }

    /// The value of the first field with `tag`.
    subscript(tag: UInt8) -> Value? {
        fields.first { $0.tag == tag }?.value
    }

    /// The payload size of a bytes or str field, nil for a fixed-size one.
    private static func payloadCount(_ value: Value) -> Int? {
        switch value {
        case .bytes(let bytes): bytes.count
        case .str(let text): text.utf8.count
        case .i32, .i64, .f64: nil
        }
    }

    /// The bytes its bytes and str fields hold: what a received message
    /// keeps on the heap until it runs (the inbox's byte limit counts it).
    var payloadByteCount: Int {
        fields.reduce(0) { $0 + (Self.payloadCount($1.value) ?? 0) }
    }

    /// The payload bytes of the fields at `shared`: at most
    /// ``ChromiumHostSharedRegion/maxBytes`` together.
    func sharedByteCount(_ shared: [Int]) -> Int {
        shared.reduce(0) { $0 + (fields.indices.contains($1) ? Self.payloadCount(fields[$1].value) ?? 0 : 0) }
    }

    /// The bytes or str payload of field `index` (one of ``sharedFieldIndices()``).
    func payload(at index: Int) -> [UInt8] {
        switch fields[index].value {
        case .bytes(let bytes): bytes
        case .str(let text): Array(text.utf8)
        case .i32, .i64, .f64: []
        }
    }

    /// The bytes and str fields that go in shared regions so the frame fits
    /// (ascending): every one over 65,535 bytes, then the largest until the
    /// body is at most ``maxBody``. Empty when the frame fits as it is.
    /// `SharedFields` in `chromium_host_control.cc` picks the same.
    func sharedFieldIndices() -> [Int] {
        var body = 0
        var oversized = false
        for field in fields {
            let count = Self.payloadCount(field.value) ?? Self.fixedSize(field.value)
            oversized = oversized || count > Int(UInt16.max)
            body += Self.fieldHeaderSize + count
        }
        // The common frame: nothing to share, and no allocation.
        guard oversized || body > Self.maxBody else { return [] }
        var shared: [Int] = []
        var candidates: [(index: Int, count: Int)] = []
        body = 0
        for (index, field) in fields.enumerated() {
            guard let count = Self.payloadCount(field.value) else {
                body += Self.fieldHeaderSize + Self.fixedSize(field.value)
                continue
            }
            if count > Int(UInt16.max) {
                shared.append(index)
                body += Self.fieldHeaderSize + Self.sharedFieldSize
            } else {
                body += Self.fieldHeaderSize + count
                if count > Self.sharedFieldSize { candidates.append((index, count)) }
            }
        }
        // Largest first; equal sizes keep field order (the C++ side's stable_sort).
        candidates.sort { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
        for candidate in candidates where body > Self.maxBody {
            shared.append(candidate.index)
            body -= candidate.count - Self.sharedFieldSize
        }
        return shared.sorted()
    }

    private static func fixedSize(_ value: Value) -> Int {
        if case .i32 = value { return 4 }
        return 8
    }

    /// The frame, or nil when it would break a bound: a body over
    /// ``maxBody``, a field over 65,535 bytes, more than ``maxFds`` descriptors,
    /// shared fields over ``ChromiumHostSharedRegion/maxBytes`` together.
    /// The fields at `shared` (from ``sharedFieldIndices()``) are written as
    /// shared fields, and the frame declares one more descriptor for each.
    func encoded(sharing shared: [Int] = []) -> [UInt8]? {
        let fdCount = fds.count + shared.count
        guard fdCount <= Self.maxFds, sharedByteCount(shared) <= ChromiumHostSharedRegion.maxBytes else { return nil }
        var body: [UInt8] = []
        var nextShared = 0
        for (index, field) in fields.enumerated() {
            if nextShared < shared.count, shared[nextShared] == index {
                nextShared += 1
                guard let count = Self.payloadCount(field.value), count > 0,
                      count <= ChromiumHostSharedRegion.maxBytes else { return nil }
                if case .str = field.value {
                    Self.putField(&body, type: Self.sharedStrType, tag: field.tag, length: Self.sharedFieldSize)
                } else {
                    Self.putField(&body, type: Self.sharedBytesType, tag: field.tag, length: Self.sharedFieldSize)
                }
                Self.put(&body, UInt64(count))
                guard body.count <= Self.maxBody else { return nil }
                continue
            }
            switch field.value {
            case .i32(let value):
                Self.putField(&body, type: 1, tag: field.tag, length: 4)
                Self.put(&body, UInt32(bitPattern: value))
            case .i64(let value):
                Self.putField(&body, type: 2, tag: field.tag, length: 8)
                Self.put(&body, UInt64(bitPattern: value))
            case .f64(let value):
                Self.putField(&body, type: 3, tag: field.tag, length: 8)
                Self.put(&body, value.bitPattern)
            case .bytes(let bytes):
                guard bytes.count <= Int(UInt16.max) else { return nil }
                Self.putField(&body, type: 4, tag: field.tag, length: bytes.count)
                body.append(contentsOf: bytes)
            case .str(let text):
                let bytes = Array(text.utf8)
                guard bytes.count <= Int(UInt16.max) else { return nil }
                Self.putField(&body, type: 5, tag: field.tag, length: bytes.count)
                body.append(contentsOf: bytes)
            }
            guard body.count <= Self.maxBody else { return nil }
        }
        guard nextShared == shared.count else { return nil }  // an index past the fields, or not ascending
        var frame: [UInt8] = []
        frame.reserveCapacity(Self.headerSize + body.count)
        Self.put(&frame, UInt32(body.count))
        Self.put(&frame, op)
        Self.put(&frame, (isReply ? Self.replyFlag : 0) | UInt16(fdCount))
        Self.put(&frame, token)
        frame.append(contentsOf: body)
        return frame
    }

    enum Decoded: Equatable, Sendable {
        /// A whole frame, and how many bytes of the input it took.
        case frame(ChromiumHostControlMessage, consumed: Int)
        /// The input ends inside a frame.
        case needMore
        /// The stream is broken: the connection ends.
        case malformed
    }

    /// Decodes the first frame of `bytes`. `fds` holds the descriptors
    /// received and not given to a frame yet, oldest first; a frame takes its
    /// count from the front. Malformed as soon as the header is bad, before
    /// its body arrives. Shared fields are read here: each region is copied
    /// into its field and closed, and the message's ``fds`` are only the
    /// sender's own descriptors.
    static func decode(_ bytes: ArraySlice<UInt8>, fds: inout [Int32]) -> Decoded {
        guard bytes.count >= headerSize else { return .needMore }
        let base = bytes.startIndex
        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size {
                value |= T(truncatingIfNeeded: bytes[base + offset + index]) << (8 * index)
            }
            return value
        }
        let length = Int(get(0, UInt32.self))
        let flags = get(6, UInt16.self)
        let fdCount = Int(flags & fdCountMask)
        guard length <= maxBody, flags & ~knownFlags == 0, fdCount <= maxFds else { return .malformed }
        guard bytes.count >= headerSize + length else { return .needMore }
        var message = ChromiumHostControlMessage(op: get(4, UInt16.self), token: get(8, UInt32.self),
                                                 isReply: flags & replyFlag != 0)
        var at = headerSize
        let end = headerSize + length
        // The shared fields: their index and byte count, and their total.
        var shared: [(index: Int, count: Int)] = []
        var sharedTotal = 0
        while at < end {
            guard end - at >= fieldHeaderSize else { return .malformed }
            let type = bytes[base + at]
            let tag = bytes[base + at + 1]
            let fieldLength = Int(get(at + 2, UInt16.self))
            at += fieldHeaderSize
            guard fieldLength <= end - at else { return .malformed }
            let value: Value
            switch (type, fieldLength) {
            case (1, 4): value = .i32(Int32(bitPattern: get(at, UInt32.self)))
            case (2, 8): value = .i64(Int64(bitPattern: get(at, UInt64.self)))
            case (3, 8): value = .f64(Double(bitPattern: get(at, UInt64.self)))
            case (4, _): value = .bytes(Array(bytes[(base + at)..<(base + at + fieldLength)]))
            case (5, _):
                let raw = bytes[(base + at)..<(base + at + fieldLength)]
                let text = String(decoding: raw, as: UTF8.self)
                // Invalid UTF-8 decodes to U+FFFD, which does not encode back to the same bytes.
                guard text.utf8.elementsEqual(raw) else { return .malformed }
                value = .str(text)
            case (sharedBytesType, sharedFieldSize), (sharedStrType, sharedFieldSize):
                let count = get(at, UInt64.self)
                guard count > 0, count <= UInt64(ChromiumHostSharedRegion.maxBytes - sharedTotal) else { return .malformed }
                sharedTotal += Int(count)
                shared.append((message.fields.count, Int(count)))
                // Filled from the region once the frame's descriptors are taken.
                value = type == sharedStrType ? .str("") : .bytes([])
            default: return .malformed
            }
            at += fieldLength
            message.fields.append(Field(tag: tag, value: value))
        }
        guard fds.count >= fdCount, shared.count <= fdCount else { return .malformed }
        let frameFds = Array(fds.prefix(fdCount))
        fds.removeFirst(fdCount)
        let regions = Array(frameFds.suffix(shared.count))
        let taken = Array(frameFds.dropLast(shared.count))
        let filled = fillSharedFields(&message, shared, from: regions)
        for region in regions { Darwin.close(region) }
        guard filled else {
            for own in taken { Darwin.close(own) }
            return .malformed
        }
        message.fds = taken
        return .frame(message, consumed: end)
    }

    /// Copies each shared field's region into it; false when one is not a
    /// read-only region of its byte count, or a str is not UTF-8.
    private static func fillSharedFields(_ message: inout ChromiumHostControlMessage,
                                         _ shared: [(index: Int, count: Int)], from regions: [Int32]) -> Bool {
        for (field, region) in zip(shared, regions) {
            guard let bytes = ChromiumHostSharedRegion.bytes(in: region, count: field.count) else { return false }
            guard case .str = message.fields[field.index].value else {
                message.fields[field.index].value = .bytes(bytes)
                continue
            }
            let text = String(decoding: bytes, as: UTF8.self)
            guard text.utf8.elementsEqual(bytes) else { return false }
            message.fields[field.index].value = .str(text)
        }
        return true
    }

    /// Whether `pending` descriptors, received and not taken by a whole frame,
    /// can belong to the frame `rest` starts. They travel with a frame's first
    /// byte, so they must come with a started frame and be no more than its
    /// header declares; extra ones are malformed (Mojo rejects a message whose
    /// handle count does not match what came with it).
    static func pendingFdsFit(_ rest: ArraySlice<UInt8>, pending: Int) -> Bool {
        guard pending > 0 else { return true }
        guard !rest.isEmpty else { return false }
        guard rest.count >= headerSize else { return pending <= maxFds }
        let flags = UInt16(rest[rest.startIndex + 6]) | UInt16(rest[rest.startIndex + 7]) << 8
        return pending <= Int(flags & fdCountMask)
    }

    private static func putField(_ out: inout [UInt8], type: UInt8, tag: UInt8, length: Int) {
        out.append(type)
        out.append(tag)
        put(&out, UInt16(length))
    }

    private static func put<T: FixedWidthInteger>(_ out: inout [UInt8], _ value: T) {
        out.appendLittleEndian(value)
    }
}
#endif
