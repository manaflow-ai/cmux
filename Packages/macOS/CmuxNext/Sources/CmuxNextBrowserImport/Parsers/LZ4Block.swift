#if canImport(Compression)
import Compression
#endif

/// One raw LZ4 block (lz4's doc/lz4_Block_format.md), what Firefox's mozLz4 files hold: Compression's
/// COMPRESSION_LZ4_RAW on Apple platforms, ``decodeInSwift(_:size:)`` where there is no Compression (the Linux
/// tier). The answer is `size` bytes or nil.
enum LZ4Block {
    static func decode(_ block: [UInt8], size: Int) -> [UInt8]? {
        guard size > 0, !block.isEmpty else { return nil }
        #if canImport(Compression)
        var output = [UInt8](repeating: 0, count: size)
        // SAFETY: the decoder reads at most block.count bytes of `block` and writes at most `size`
        // (output.count) bytes into `output`, the counts passed; Swift lends both arrays for the call.
        let written = unsafe compression_decode_buffer(&output, size, block, block.count, nil, COMPRESSION_LZ4_RAW)
        return written == size ? output : nil
        #else
        return decodeInSwift(block, size: size)
        #endif
    }

    /// The block format in checked Swift: each sequence is a token (literal count, match length - 4), the
    /// literals, then a little-endian 16-bit offset back into the output and the match; a count of 15 goes on in
    /// bytes of 255 and one last smaller byte. The last sequence has literals only. Any count past the input or
    /// past `size`, and an offset of 0 or before the output's start, is a bad block.
    static func decodeInSwift(_ block: [UInt8], size: Int) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(size)
        var index = 0
        while index < block.count {
            let token = block[index]
            index += 1
            guard let literals = length(Int(token >> 4), in: block, at: &index, limit: size - output.count),
                  literals <= block.count - index else { return nil }
            output.append(contentsOf: block[index..<(index + literals)])
            index += literals
            if index == block.count { return output.count == size ? output : nil }
            guard block.count - index >= 2 else { return nil }
            let offset = Int(block[index]) | Int(block[index + 1]) << 8
            index += 2
            guard offset > 0, offset <= output.count,
                  let extra = length(Int(token & 0x0F), in: block, at: &index, limit: size - output.count - 4) else { return nil }
            let match = extra + 4
            // The match may overlap the bytes it copies (offset < match): copy front to back, one byte at a time.
            let start = output.count - offset
            for position in start..<(start + match) { output.append(output[position]) }
        }
        return nil
    }

    /// A token's count `nibble`, continued in bytes of 255 when it is 15; nil past the input or above `limit`.
    private static func length(_ nibble: Int, in block: [UInt8], at index: inout Int, limit: Int) -> Int? {
        guard nibble == 15 else { return nibble <= limit ? nibble : nil }
        var total = nibble
        for byte in block.dropFirst(index) {
            index += 1
            total += Int(byte)
            guard total <= limit else { return nil }
            if byte != 255 { return total }
        }
        return nil
    }
}
