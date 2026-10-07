import Foundation

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
