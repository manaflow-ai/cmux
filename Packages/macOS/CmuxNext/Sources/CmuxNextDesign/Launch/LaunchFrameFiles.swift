public import CoreGraphics
public import Foundation

/// The file names of the last frames the app keeps on disk for the next launch, one file per tab: a
/// terminal's (`TerminalLaunchFrames`) and a browser page's (`BrowserPageFrames`). A frame is
/// `<key>@<scale>x.jpg` (a PNG keeps the same name; the read tells the formats apart by their bytes), so a
/// key never has two files and a write that races another replaces one file.
public nonisolated struct LaunchFrameFiles {
    public nonisolated init() {}
    /// The file of `key`'s frame at `scale` (1 to 3).
    public static func name(_ key: String, scale: Int) -> String { "\(key)@\(max(1, min(3, scale)))x.jpg" }

    /// The tab key of a saved frame (`<key>@<scale>x.jpg`, scale 1 to 3); nil for any other file, such as Foundation's
    /// atomic-write file beside one before its rename (`<key>@2x.jpg.sb-<id>`).
    public static func owner(of file: String) -> String? {
        guard file.hasSuffix("x.jpg"), let at = file.lastIndex(of: "@") else { return nil }
        let scale = file[file.index(after: at)..<file.index(file.endIndex, offsetBy: -"x.jpg".count)]
        guard scale.count == 1, let digit = scale.first, ("1"..."3").contains(digit) else { return nil }
        return String(file[..<at])
    }

    /// A frame's file data: a PNG when it shows clear pixels (unfiltered: cheap for flat colors and text), else a JPEG
    /// at `jpegQuality`; nil when it does not encode or is larger than `maximumBytes` (a file the next read refuses).
    public static func encoded(_ frame: CGImage, jpegQuality: Double, maximumBytes: Int) -> Data? {
        let data = frame.showsClearPixels ? frame.unfilteredPNGData() : frame.pageImageData(png: false, jpegQuality: jpegQuality)
        guard let data, data.count <= maximumBytes else { return nil }
        return data
    }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    public static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
