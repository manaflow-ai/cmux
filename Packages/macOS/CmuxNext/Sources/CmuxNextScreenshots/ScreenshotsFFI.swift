import CCmuxScreenshots
import CmuxNextFileGrid
import CmuxNextFiles
import Foundation

/// The pane's rules live in Rust (cmux-tui/crates/cmux-screenshots, include/cmux_screenshots.h):
/// these pass strings in and out of that C ABI.
nonisolated enum ScreenshotsFFI {
    /// Runs `body` with `text`'s UTF-8 bytes and their length.
    static func bytes<R>(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
        var text = text
        return text.withUTF8 { body($0.baseAddress, $0.count) }
    }

    /// Runs `body` with every string's UTF-8 bytes and length, in one buffer.
    static func strings<R>(_ texts: [String], _ body: ([(bytes: UnsafePointer<UInt8>?, count: Int)]) -> R) -> R {
        Array(texts.joined().utf8).withUnsafeBufferPointer { buffer in
            var offset = 0
            return body(texts.map { text in
                defer { offset += text.utf8.count }
                return (buffer.baseAddress.map { $0 + offset }, text.utf8.count)
            })
        }
    }

    /// A string the library returned, freed; nil for null.
    static func take(_ string: UnsafeMutablePointer<CChar>?) -> String? {
        guard let string else { return nil }
        defer { cmux_screenshots_string_free(string) }
        return String(cString: string)
    }

    /// A JSON value as text (`[]` when it cannot be written).
    static func json(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The C ABI's kinds, raw value 1 first (0: not listed).
    private static let kinds: [FileGridMediaKind] = [.image, .video, .other]

    /// The C ABI's kind (1 image, 2 video, 3 other).
    static func raw(_ kind: FileGridMediaKind) -> UInt32 { UInt32((kinds.firstIndex(of: kind) ?? 2) + 1) }

    /// The kind of a C ABI raw value; nil for 0 (not listed).
    static func kind(_ raw: UInt32) -> FileGridMediaKind? { (1...3).contains(raw) ? kinds[Int(raw) - 1] : nil }

    /// The C ABI's entry kind (1 file, 2 folder, 3 package, 0 other).
    static func raw(_ kind: FileKind) -> UInt32 { [.file, .folder, .package].firstIndex(of: kind).map { UInt32($0 + 1) } ?? 0 }

    /// What the system says a file name's extension is, as the C ABI's kind.
    static func systemKind(ofFileNamed name: String) -> UInt32 {
        raw(FileGridMediaKind(pathExtension: (name as NSString).pathExtension))
    }
}

/// A Rust object, freed with the last value that holds it. Its address is a plain value, so the handle is
/// Sendable and its nonisolated deinit frees it; the caller keeps a changing object to one owner.
/// Handles never tell two values apart: a value type's synthesized `==` and hash read only its own fields.
nonisolated final class RustHandle: Sendable, Hashable {
    private let address: UInt
    private let free: @Sendable (OpaquePointer?) -> Void
    var pointer: OpaquePointer? { OpaquePointer(bitPattern: address) }

    init(_ pointer: OpaquePointer?, free: @escaping @Sendable (OpaquePointer?) -> Void) {
        address = UInt(bitPattern: pointer)
        self.free = free
    }

    deinit { free(pointer) }
    static func == (lhs: RustHandle, rhs: RustHandle) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}
