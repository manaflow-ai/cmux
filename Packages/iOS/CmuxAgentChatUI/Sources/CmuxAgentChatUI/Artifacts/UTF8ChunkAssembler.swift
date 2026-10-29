import Foundation

/// Incrementally decodes UTF-8 while retaining only an incomplete trailing scalar.
struct UTF8ChunkAssembler: Sendable {
    private var pendingBytes = Data()

    /// Appends raw bytes and returns the complete Unicode scalars now available.
    ///
    /// - Parameters:
    ///   - data: The next contiguous bytes in the stream.
    ///   - eof: Whether these are the final bytes in the stream.
    /// - Returns: Decoded text excluding any buffered incomplete trailing scalar.
    /// - Throws: ``UTF8ChunkAssemblerError/invalidEncoding`` for malformed UTF-8
    ///   or an incomplete scalar at EOF.
    mutating func append(_ data: Data, eof: Bool) throws -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(pendingBytes.count + data.count)
        bytes.append(contentsOf: pendingBytes)
        bytes.append(contentsOf: data)
        pendingBytes.removeAll(keepingCapacity: true)

        var index = 0
        var validEnd = bytes.count
        while index < bytes.count {
            let lead = bytes[index]
            if lead <= 0x7F {
                index += 1
                continue
            }

            let scalarLength = try Self.scalarLength(for: lead)
            let availableLength = bytes.count - index
            if availableLength < scalarLength {
                try Self.validateAvailableScalarPrefix(
                    bytes,
                    start: index,
                    availableLength: availableLength
                )
                guard !eof else {
                    throw UTF8ChunkAssemblerError.invalidEncoding
                }
                validEnd = index
                pendingBytes.append(contentsOf: bytes[index...])
                break
            }

            try Self.validateCompleteScalar(bytes, start: index, length: scalarLength)
            index += scalarLength
        }

        guard validEnd > 0 else { return "" }
        return String(decoding: bytes[..<validEnd], as: UTF8.self)
    }

    private static func scalarLength(for lead: UInt8) throws -> Int {
        switch lead {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            throw UTF8ChunkAssemblerError.invalidEncoding
        }
    }

    private static func validateAvailableScalarPrefix(
        _ bytes: [UInt8],
        start: Int,
        availableLength: Int
    ) throws {
        guard availableLength > 1 else { return }
        try validateSecondByte(bytes[start + 1], lead: bytes[start])
        if availableLength > 2 {
            for offset in 2..<availableLength {
                guard isContinuationByte(bytes[start + offset]) else {
                    throw UTF8ChunkAssemblerError.invalidEncoding
                }
            }
        }
    }

    private static func validateCompleteScalar(
        _ bytes: [UInt8],
        start: Int,
        length: Int
    ) throws {
        try validateSecondByte(bytes[start + 1], lead: bytes[start])
        if length > 2 {
            for offset in 2..<length {
                guard isContinuationByte(bytes[start + offset]) else {
                    throw UTF8ChunkAssemblerError.invalidEncoding
                }
            }
        }
    }

    private static func validateSecondByte(_ byte: UInt8, lead: UInt8) throws {
        let isValid: Bool
        switch lead {
        case 0xE0:
            isValid = (0xA0...0xBF).contains(byte)
        case 0xED:
            isValid = (0x80...0x9F).contains(byte)
        case 0xF0:
            isValid = (0x90...0xBF).contains(byte)
        case 0xF4:
            isValid = (0x80...0x8F).contains(byte)
        default:
            isValid = isContinuationByte(byte)
        }
        guard isValid else {
            throw UTF8ChunkAssemblerError.invalidEncoding
        }
    }

    private static func isContinuationByte(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
    }
}
