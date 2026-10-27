/// What a file name extension holds, by the system's type registry.
public enum FileTypeContent: Sendable, Equatable {
    /// The registry does not know the extension.
    case undeclared
    /// Text a code editor shows: plain text, source code, scripts, JSON, XML, property lists, YAML.
    case text
    /// A known type that is not text (an Office document, an archive, a disk image).
    case other
}

/// The system's file type registry by extension: the one seam ``FileOpenKind`` and
/// ``DirectoryLister`` ask what a name is. ``SystemFileTypes`` is the platform's answer (Launch
/// Services' `UTType` on macOS, a fixed table on Linux), the way Chromium keeps one
/// `GetMimeTypeFromExtension` over per-platform lookups (net/base/mime_util.cc,
/// net/base/platform_mime_util_mac.mm, net/base/platform_mime_util_linux.cc). Tests pass a fake.
public protocol FileTypeRegistry: Sendable {
    /// Whether a directory named with `pathExtension` (lowercased, no dot) is one item (an app, a bundle).
    func isPackage(pathExtension: String) -> Bool

    /// What a file named with `pathExtension` (lowercased, no dot, not empty) holds.
    func content(pathExtension: String) -> FileTypeContent
}
