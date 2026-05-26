import Foundation

enum MojoWireMessage {
    static let messageHeaderSize = 56

    static func message(method: UInt32, payload: Data, flags: UInt32 = 0, requestID: UInt64 = 0) -> Data {
        var data = Data(count: align(messageHeaderSize + payload.count))
        data.writeUInt32(56, at: 0)
        data.writeUInt32(3, at: 4)
        data.writeUInt32(0, at: 8)
        data.writeUInt32(method, at: 12)
        data.writeUInt32(flags, at: 16)
        data.writeUInt32(0, at: 20)
        data.writeUInt64(requestID, at: 24)
        data.writeUInt64(24, at: 32)
        data.writeUInt64(0, at: 40)
        data.writeInt64(0, at: 48)
        data.replaceSubrange(messageHeaderSize..<messageHeaderSize + payload.count, with: payload)
        return data
    }

    static func utf8String(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        let stringSize = 8 + bytes.count
        var data = Data(count: align(stringSize))
        data.writeUInt32(UInt32(stringSize), at: 0)
        data.writeUInt32(UInt32(bytes.count), at: 4)
        data.replaceSubrange(8..<8 + bytes.count, with: bytes)
        return data
    }

    static func uint8Array(_ values: [UInt8]) -> Data {
        let arraySize = 8 + values.count
        var data = Data(count: align(arraySize))
        data.writeUInt32(UInt32(arraySize), at: 0)
        data.writeUInt32(UInt32(values.count), at: 4)
        data.replaceSubrange(8..<8 + values.count, with: values)
        return data
    }

    static func uint16Array(_ values: [UInt16]) -> Data {
        let arraySize = 8 + values.count * 2
        var data = Data(count: align(arraySize))
        data.writeUInt32(UInt32(arraySize), at: 0)
        data.writeUInt32(UInt32(values.count), at: 4)
        for (index, value) in values.enumerated() {
            data.writeUInt16(value, at: 8 + index * 2)
        }
        return data
    }

    static func string16(_ value: String) -> Data {
        let arrayData = uint16Array(Array(value.utf16))
        var data = Data(count: align(16 + arrayData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + arrayData.count, with: arrayData)
        return data
    }

    static func stringArray(_ values: [String]) -> Data {
        var data = pointerArrayHeader(count: values.count)
        for (index, value) in values.enumerated() {
            data.appendMojoPointer(child: utf8String(value), pointerOffset: 8 + index * 8)
        }
        return data
    }

    static func structPointerArray(_ values: [Data]) -> Data {
        var data = pointerArrayHeader(count: values.count)
        for (index, value) in values.enumerated() {
            data.appendMojoPointer(child: value, pointerOffset: 8 + index * 8)
        }
        return data
    }

    static func align(_ value: Int) -> Int {
        (value + 7) & ~7
    }

    private static func pointerArrayHeader(count: Int) -> Data {
        let arraySize = 8 + count * 8
        var data = Data(count: align(arraySize))
        data.writeUInt32(UInt32(arraySize), at: 0)
        data.writeUInt32(UInt32(count), at: 4)
        return data
    }
}

enum MojoWireDataError: Error, CustomStringConvertible, Equatable {
    case outOfBounds(offset: Int, length: Int, count: Int)
    case invalidRelativePointer(offset: Int, relative: UInt64)
    case invalidStringSize(offset: Int, size: UInt32, byteCount: UInt32)
    case invalidUTF8(offset: Int, byteCount: UInt32)
    case invalidResponse(String)

    var description: String {
        switch self {
        case let .outOfBounds(offset, length, count):
            "Mojo wire data range \(offset)..<\(offset + length) exceeds \(count) bytes"
        case let .invalidRelativePointer(offset, relative):
            "Mojo wire relative pointer at \(offset) is invalid: \(relative)"
        case let .invalidStringSize(offset, size, byteCount):
            "Mojo wire string at \(offset) has invalid size \(size) for \(byteCount) bytes"
        case let .invalidUTF8(offset, byteCount):
            "Mojo wire string at \(offset) is not valid UTF-8 (\(byteCount) bytes)"
        case let .invalidResponse(message):
            "Invalid Mojo response: \(message)"
        }
    }
}

extension Data {
    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        write(value.littleEndian, at: offset)
    }

    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        write(value.littleEndian, at: offset)
    }

    mutating func writeInt32(_ value: Int32, at offset: Int) {
        write(UInt32(bitPattern: value).littleEndian, at: offset)
    }

    mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        write(value.littleEndian, at: offset)
    }

    mutating func writeInt64(_ value: Int64, at offset: Int) {
        write(value.littleEndian, at: offset)
    }

    mutating func writeDouble(_ value: Double, at offset: Int) {
        write(value.bitPattern.littleEndian, at: offset)
    }

    mutating func writeFloat32(_ value: Float, at offset: Int) {
        write(value.bitPattern.littleEndian, at: offset)
    }

    mutating func write<T>(_ value: T, at offset: Int) {
        Swift.withUnsafeBytes(of: value) { bytes in
            replaceSubrange(offset..<offset + bytes.count, with: bytes)
        }
    }

    func mojoUInt32(at offset: Int) throws -> UInt32 {
        try requireMojoRange(offset: offset, length: 4)
        let value = self[offset..<offset + 4].enumerated().reduce(UInt32(0)) { result, item in
            result | UInt32(item.element) << UInt32(item.offset * 8)
        }
        return value
    }

    func mojoInt32(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try mojoUInt32(at: offset))
    }

    func mojoUInt8(at offset: Int) throws -> UInt8 {
        try requireMojoRange(offset: offset, length: 1)
        return self[offset]
    }

    func mojoUInt64(at offset: Int) throws -> UInt64 {
        try requireMojoRange(offset: offset, length: 8)
        let value = self[offset..<offset + 8].enumerated().reduce(UInt64(0)) { result, item in
            result | UInt64(item.element) << UInt64(item.offset * 8)
        }
        return value
    }

    func mojoFloat32(at offset: Int) throws -> Float {
        Float(bitPattern: try mojoUInt32(at: offset))
    }

    func mojoRelativeOffset(pointerOffset: Int) throws -> Int {
        let relative = try mojoUInt64(at: pointerOffset)
        guard relative > 0, relative <= UInt64(Int.max) else {
            throw MojoWireDataError.invalidRelativePointer(offset: pointerOffset, relative: relative)
        }
        return pointerOffset + Int(relative)
    }

    func mojoString(pointerOffset: Int) throws -> String {
        let stringOffset = try mojoRelativeOffset(pointerOffset: pointerOffset)
        let stringSize = try mojoUInt32(at: stringOffset)
        let byteCount = try mojoUInt32(at: stringOffset + 4)
        guard stringSize >= 8, byteCount <= stringSize - 8 else {
            throw MojoWireDataError.invalidStringSize(offset: stringOffset, size: stringSize, byteCount: byteCount)
        }
        let bytesOffset = stringOffset + 8
        try requireMojoRange(offset: bytesOffset, length: Int(byteCount))
        guard let string = String(data: self[bytesOffset..<bytesOffset + Int(byteCount)], encoding: .utf8) else {
            throw MojoWireDataError.invalidUTF8(offset: stringOffset, byteCount: byteCount)
        }
        return string
    }

    func mojoUInt8Array(pointerOffset: Int) throws -> [UInt8] {
        let header = try mojoArrayHeader(pointerOffset: pointerOffset)
        guard header.byteCount >= 8 + header.count else {
            throw MojoWireDataError.outOfBounds(offset: header.offset, length: 8 + header.count, count: header.offset + header.byteCount)
        }
        try requireMojoRange(offset: header.elementsOffset, length: header.count)
        return Array(self[header.elementsOffset..<header.elementsOffset + header.count])
    }

    func mojoStringArray(pointerOffset: Int) throws -> [String] {
        try mojoPointerArray(pointerOffset: pointerOffset) { elementPointerOffset in
            try mojoString(pointerOffset: elementPointerOffset)
        }
    }

    func mojoStructPointerArray<Element>(
        pointerOffset: Int,
        decode: (Int) throws -> Element
    ) throws -> [Element] {
        try mojoPointerArray(pointerOffset: pointerOffset) { elementPointerOffset in
            try decode(mojoRelativeOffset(pointerOffset: elementPointerOffset))
        }
    }

    private func mojoPointerArray<Element>(
        pointerOffset: Int,
        decode: (Int) throws -> Element
    ) throws -> [Element] {
        let header = try mojoArrayHeader(pointerOffset: pointerOffset)
        let pointersByteCount = header.count * 8
        guard header.byteCount >= 8 + pointersByteCount else {
            throw MojoWireDataError.outOfBounds(
                offset: header.offset,
                length: 8 + pointersByteCount,
                count: header.offset + header.byteCount
            )
        }
        try requireMojoRange(offset: header.elementsOffset, length: pointersByteCount)
        var values: [Element] = []
        values.reserveCapacity(header.count)
        for index in 0..<header.count {
            values.append(try decode(header.elementsOffset + index * 8))
        }
        return values
    }

    private func mojoArrayHeader(pointerOffset: Int) throws -> (offset: Int, byteCount: Int, count: Int, elementsOffset: Int) {
        let arrayOffset = try mojoRelativeOffset(pointerOffset: pointerOffset)
        let byteCount = Int(try mojoUInt32(at: arrayOffset))
        let count = try mojoUInt32(at: arrayOffset + 4)
        guard byteCount >= 8 else {
            throw MojoWireDataError.outOfBounds(offset: arrayOffset, length: byteCount, count: self.count)
        }
        try requireMojoRange(offset: arrayOffset, length: byteCount)
        let elementsOffset = arrayOffset + 8
        return (offset: arrayOffset, byteCount: byteCount, count: Int(count), elementsOffset: elementsOffset)
    }

    mutating func appendMojoPointer(child: Data, pointerOffset: Int) {
        let childOffset = count
        writeUInt64(UInt64(childOffset - pointerOffset), at: pointerOffset)
        append(child)
    }

    private func requireMojoRange(offset: Int, length: Int) throws {
        guard offset >= 0, length >= 0, offset <= count, offset + length <= count else {
            throw MojoWireDataError.outOfBounds(offset: offset, length: length, count: count)
        }
    }
}
