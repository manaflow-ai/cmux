import Foundation

extension AcpmuxPaneSocket {
    /// The frame as native UTF-8. URLSessionWebSocketTask hands a text frame over as a bridged
    /// NSString (UTF-16 for any non-ASCII text), and every later byte read (the size, the
    /// duplicate-key check, the method scan, `contains`) would walk it one character at a time
    /// through `characterAtIndex:`. One bulk transcode here makes each of those a native read.
    /// A native string comes back as it is.
    nonisolated static func nativeUTF8(_ text: String) -> String {
        if text.utf8.withContiguousStorageIfAvailable({ _ in true }) == true { return text }
        #if canImport(ObjectiveC)
        let cocoa = text as NSString
        let utf8 = String.Encoding.utf8.rawValue
        let count = cocoa.lengthOfBytes(using: utf8)
        var complete = false
        let native = String(unsafeUninitializedCapacity: count) { buffer in
            var used = 0
            var rest = NSRange(location: 0, length: 0)
            complete = cocoa.getBytes(buffer.baseAddress, maxLength: count, usedLength: &used, encoding: utf8,
                                      options: [], range: NSRange(location: 0, length: cocoa.length), remaining: &rest)
                && rest.length == 0 && used == count
            return complete ? used : 0
        }
        if complete { return native }
        #endif
        // Not UTF-8 encodable in bulk (an unpaired surrogate): the standard library's repairing copy.
        var copy = text
        copy.makeContiguousUTF8()
        return copy
    }
}
