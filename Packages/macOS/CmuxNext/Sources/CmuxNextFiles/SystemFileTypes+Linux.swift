#if !canImport(UniformTypeIdentifiers)
/// The type registry on a system without Launch Services: a fixed table of the extensions whose
/// answer differs from the default (an undeclared extension opens as text), like the built-in
/// mappings Chromium reads before the platform's (net/base/mime_util.cc, `kPrimaryMappings`).
public struct SystemFileTypes: FileTypeRegistry {
    /// Makes the registry. It holds no state.
    public init() {}

    public func isPackage(pathExtension ext: String) -> Bool {
        FileOpenKind.packageExtensions.contains(ext)
    }

    public func content(pathExtension ext: String) -> FileTypeContent {
        if Self.textExtensions.contains(ext) { return .text }
        if Self.otherExtensions.contains(ext) { return .other }
        return .undeclared
    }

    /// Text types macOS declares (UTType conforms to text, source code, script, JSON, XML, plist or YAML).
    static let textExtensions: Set<String> = [
        "txt", "text", "rtf", "json", "xml", "plist", "yaml", "yml", "sh", "bash", "zsh", "fish", "py", "rb", "pl",
        "php", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "js", "css", "scss", "less", "s", "asm", "diff",
        "patch", "make", "mk",
    ]

    /// Known types that are not text: documents, archives, disk images, binaries, fonts and media
    /// the preview does not play.
    static let otherExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "epub",
        "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4", "dmg", "iso", "img", "pkg", "deb", "rpm",
        "apk", "ipa", "exe", "dll", "so", "dylib", "o", "a", "class", "jar", "wasm", "ttf", "otf", "woff", "woff2",
        "sqlite", "db", "psd", "ai", "eps", "sketch", "raw", "cr2", "nef", "avi", "mkv", "wmv", "flv",
    ]
}
#endif
