import Foundation

/// Decodes argv boundaries from KERN_PROCARGS2 without retaining the environment.
struct CodexWriterProcessArguments {
    func decode(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        var count: Int32 = 0
        withUnsafeMutableBytes(of: &count) { $0.copyBytes(from: bytes.prefix(4)) }
        guard count > 0, count < 65_536 else { return nil }
        var cursor = 4
        guard consumeString(bytes, cursor: &cursor) != nil else { return nil }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard let argument = consumeString(bytes, cursor: &cursor) else { return nil }
            result.append(argument)
        }
        return result
    }

    private func consumeString(_ bytes: [UInt8], cursor: inout Int) -> String? {
        let start = cursor
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        guard cursor < bytes.count, let result = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
        cursor += 1
        return result
    }
}
