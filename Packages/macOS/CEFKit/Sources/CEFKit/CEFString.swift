import CCEF
import Foundation

// CEF strings are UTF-16 buffers with an optional destructor. Fields set on
// long-lived structs (settings, request context settings) own their buffer via
// `assign`; call-scoped arguments borrow Swift string storage via
// `withCEFString` and never allocate.

extension cef_string_t {
    mutating func assign(_ string: String?) {
        if let dtor = dtor, let str = str {
            dtor(str)
        }
        self = cef_string_t()
        guard let string, !string.isEmpty else { return }
        let units = Array(string.utf16)
        let buffer = UnsafeMutablePointer<UInt16>.allocate(capacity: units.count)
        buffer.update(from: units, count: units.count)
        str = buffer
        length = numericCast(units.count)
        dtor = { $0?.deallocate() }
    }
}

func withCEFString<R>(_ string: String, _ body: (UnsafePointer<cef_string_t>) -> R) -> R {
    var units = Array(string.utf16)
    return units.withUnsafeMutableBufferPointer { buf in
        var s = cef_string_t()
        s.str = buf.baseAddress
        s.length = numericCast(buf.count)
        return withUnsafePointer(to: &s) { body($0) }
    }
}

extension String {
    init?(cefString: UnsafePointer<cef_string_t>?) {
        guard let cefString, let chars = cefString.pointee.str, cefString.pointee.length > 0 else {
            return nil
        }
        self.init(decoding: UnsafeBufferPointer(start: chars, count: numericCast(cefString.pointee.length)), as: UTF16.self)
    }

    /// Consumes a cef_string_userfree_t returned by a CEF getter.
    init?(consumingCEFUserFree userFree: cef_string_userfree_t?) {
        guard let userFree else { return nil }
        defer { CEFRuntime.stringUserfreeUtf16Free(userFree) }
        self.init(cefString: UnsafePointer(userFree))
    }
}
