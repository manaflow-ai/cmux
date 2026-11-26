import CCmuxScreenshotsFFI
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

    /// The C ABI's kind (1 image, 2 video, 3 other).
    static func raw(_ kind: FileGridMediaKind) -> UInt32 {
        switch kind {
        case .image: 1
        case .video: 2
        case .other: 3
        }
    }

    /// The kind of a C ABI raw value; nil for 0 (not listed).
    static func kind(_ raw: UInt32) -> FileGridMediaKind? {
        switch raw {
        case 1: .image
        case 2: .video
        case 3: .other
        default: nil
        }
    }

    /// The C ABI's entry kind (1 file, 2 folder, 3 package, 0 other).
    static func raw(_ kind: FileKind) -> UInt32 {
        switch kind {
        case .file: 1
        case .folder: 2
        case .package: 3
        default: 0
        }
    }

    /// What the system says a file name's extension is, as the C ABI's kind.
    static func systemKind(ofFileNamed name: String) -> UInt32 {
        raw(FileGridMediaKind(pathExtension: (name as NSString).pathExtension))
    }
}
