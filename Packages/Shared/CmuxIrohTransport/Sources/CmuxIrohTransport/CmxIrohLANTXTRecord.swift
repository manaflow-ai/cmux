public import Foundation

/// Strict, bounded TXT payload for an opaque cmux Iroh Bonjour service.
public struct CmxIrohLANTXTRecord: Equatable, Sendable {
    public static let maximumEncodedSize = 512
    public static let maximumAddressCount = 8

    public let epoch: Int64
    public let addresses: [CmxIrohLANSocketAddress]

    public init(epoch: Int64, addresses: [CmxIrohLANSocketAddress]) throws {
        let ordered = addresses.sorted { $0.value < $1.value }
        guard epoch >= 0,
              !ordered.isEmpty,
              ordered.count <= Self.maximumAddressCount,
              Set(ordered).count == ordered.count else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
        self.epoch = epoch
        self.addresses = ordered
        guard try encoded().count <= Self.maximumEncodedSize else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
    }

    /// Encodes one canonical DNS TXT string sequence.
    public func encoded() throws -> Data {
        var result = Data()
        for string in ["v=1", "e=\(epoch)"] + addresses.map({ "a=\($0.value)" }) {
            let bytes = Array(string.utf8)
            guard !bytes.isEmpty, bytes.count <= 255 else {
                throw CmxIrohLANDiscoveryError.invalidTXTRecord
            }
            result.append(UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        guard result.count <= Self.maximumEncodedSize else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
        return result
    }

    /// Decodes only the current canonical field order and rejects extensions.
    public init(encoded data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumEncodedSize else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
        var strings: [String] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let length = Int(data[offset])
            offset = data.index(after: offset)
            guard length > 0,
                  data.distance(from: offset, to: data.endIndex) >= length else {
                throw CmxIrohLANDiscoveryError.invalidTXTRecord
            }
            let end = data.index(offset, offsetBy: length)
            guard let value = String(data: data[offset..<end], encoding: .utf8),
                  value.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                throw CmxIrohLANDiscoveryError.invalidTXTRecord
            }
            strings.append(value)
            offset = end
        }
        guard strings.count >= 3,
              strings.count <= Self.maximumAddressCount + 2,
              strings[0] == "v=1",
              strings[1].hasPrefix("e=") else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
        let epochText = strings[1].dropFirst(2)
        guard !epochText.isEmpty,
              epochText.allSatisfy(\.isNumber),
              let epoch = Int64(epochText),
              epoch >= 0,
              String(epoch) == epochText else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
        let addresses = try strings.dropFirst(2).map { value -> CmxIrohLANSocketAddress in
            guard value.hasPrefix("a=") else {
                throw CmxIrohLANDiscoveryError.invalidTXTRecord
            }
            return try CmxIrohLANSocketAddress(String(value.dropFirst(2)))
        }
        try self.init(epoch: epoch, addresses: addresses)
        guard try encoded() == data else {
            throw CmxIrohLANDiscoveryError.invalidTXTRecord
        }
    }
}
