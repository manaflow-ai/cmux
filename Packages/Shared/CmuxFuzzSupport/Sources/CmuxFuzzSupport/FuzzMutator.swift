import Foundation

/// Byte and token mutations of a valid input, after libFuzzer's mutation
/// dispatcher (llvm-project compiler-rt/lib/fuzzer/FuzzerMutate.cpp): change, flip,
/// insert and erase bytes, shuffle, add to a byte, copy part of the input, insert
/// or overwrite a dictionary token and cross over with a second input.
public struct FuzzMutator: Sendable {
    /// One edit of a mutation pass.
    public enum Edit: CaseIterable, Sendable {
        case changeByte, flipBit, insertByte, eraseBytes, truncate, swapBytes, addToByte,
             duplicatePrefix, insertToken, overwriteToken, crossOver
    }

    /// Tokens the input format uses (keywords, delimiters, magic numbers).
    public var dictionary: [[UInt8]]
    /// A pass makes 1 to `maximumEdits` edits.
    public var maximumEdits: Int
    /// A mutated input never grows past this many bytes.
    public var maximumCount: Int

    public init(dictionary: [Data] = [], maximumEdits: Int = 4, maximumCount: Int = 1 << 16) {
        self.dictionary = dictionary.map { [UInt8]($0) }.filter { !$0.isEmpty }
        self.maximumEdits = max(maximumEdits, 1)
        self.maximumCount = max(maximumCount, 0)
    }

    /// `data` after 1 to `maximumEdits` random edits; `other` is the second input of a cross-over.
    public func mutate(_ data: Data, crossingWith other: Data? = nil, using rng: inout FuzzRNG) -> Data {
        var bytes = [UInt8](data)
        let partner = other.map { [UInt8]($0) } ?? []
        for _ in 0..<(1 + rng.below(maximumEdits)) {
            let edit = Edit.allCases[rng.below(Edit.allCases.count)]
            apply(edit, to: &bytes, partner: partner, using: &rng)
        }
        if bytes.count > maximumCount { bytes.removeSubrange(maximumCount...) }
        return Data(bytes)
    }

    /// Applies `edit`; an edit that cannot apply (no bytes, no tokens, no partner) inserts a byte instead,
    /// so every pass changes the input.
    public func apply(_ edit: Edit, to bytes: inout [UInt8], partner: [UInt8] = [], using rng: inout FuzzRNG) {
        switch edit {
        case .changeByte where !bytes.isEmpty:
            bytes[rng.below(bytes.count)] = rng.byte()
        case .flipBit where !bytes.isEmpty:
            bytes[rng.below(bytes.count)] ^= UInt8(1) << rng.below(8)
        case .eraseBytes where !bytes.isEmpty:
            let start = rng.below(bytes.count)
            let count = 1 + rng.below(min(bytes.count - start, 16))
            bytes.removeSubrange(start..<(start + count))
        case .truncate where !bytes.isEmpty:
            bytes.removeSubrange(rng.below(bytes.count)...)
        case .swapBytes where bytes.count > 1:
            bytes.swapAt(rng.below(bytes.count), rng.below(bytes.count))
        case .addToByte where !bytes.isEmpty:
            let index = rng.below(bytes.count)
            bytes[index] = bytes[index] &+ UInt8(truncatingIfNeeded: rng.below(71) - 35)
        case .duplicatePrefix:
            bytes += bytes.prefix(rng.below(bytes.count + 1))
        case .insertToken where !dictionary.isEmpty:
            let token = dictionary[rng.below(dictionary.count)]
            bytes.insert(contentsOf: token, at: rng.below(bytes.count + 1))
        case .overwriteToken where !dictionary.isEmpty && !bytes.isEmpty:
            let token = dictionary[rng.below(dictionary.count)]
            let start = rng.below(bytes.count)
            bytes.replaceSubrange(start..<min(start + token.count, bytes.count), with: token)
        case .crossOver where !partner.isEmpty:
            let cut = rng.below(bytes.count + 1)
            let from = rng.below(partner.count)
            bytes = Array(bytes.prefix(cut)) + partner[from...]
        default:
            bytes.insert(rng.byte(), at: rng.below(bytes.count + 1))
        }
    }
}
