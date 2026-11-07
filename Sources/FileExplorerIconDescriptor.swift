import Foundation

/// Immutable semantic icon metadata derived from a file name.
struct FileExplorerIconDescriptor: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case symbol(String)
        case badge(String)
    }

    enum ColorRole: Equatable, Sendable {
        case blue
        case cyan
        case green
        case neutral
        case orange
        case pink
        case purple
        case red
        case yellow
    }

    let kind: Kind
    let colorRole: ColorRole
    let prefersDarkBadgeText: Bool

    init(fileName: String) {
        let lowercasedName = fileName.lowercased()
        let fileURL = URL(fileURLWithPath: fileName)
        let pathExtension = fileURL.pathExtension.lowercased()

        if Self.gitFileNames.contains(lowercasedName) {
            self.init(kind: .symbol("arrow.triangle.branch"), colorRole: .orange)
            return
        }
        if lowercasedName == ".env" || lowercasedName.hasPrefix(".env.") {
            self.init(kind: .symbol("key.fill"), colorRole: .yellow)
            return
        }
        if lowercasedName == "dockerfile" || lowercasedName.hasPrefix("dockerfile.") {
            self.init(kind: .symbol("shippingbox.fill"), colorRole: .blue)
            return
        }
        if lowercasedName == "makefile" || lowercasedName.hasPrefix("makefile.") {
            self.init(kind: .symbol("hammer.fill"), colorRole: .orange)
            return
        }
        if Self.lockFileNames.contains(lowercasedName) || pathExtension == "lock" {
            self.init(kind: .symbol("lock.fill"), colorRole: .purple)
            return
        }
        if lowercasedName.hasPrefix("readme") {
            self.init(kind: .badge("MD"), colorRole: .green)
            return
        }
        if lowercasedName.hasPrefix("license") || lowercasedName.hasPrefix("copying") {
            self.init(kind: .badge("L"), colorRole: .yellow)
            return
        }

        switch pathExtension {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico":
            self.init(kind: .symbol("photo.fill"), colorRole: .purple)
        case "mov", "mp4", "m4v", "avi", "mkv", "webm":
            self.init(kind: .symbol("film.fill"), colorRole: .pink)
        case "mp3", "wav", "aif", "aiff", "m4a", "flac", "ogg":
            self.init(kind: .symbol("waveform"), colorRole: .cyan)
        case "pdf":
            self.init(kind: .badge("PDF"), colorRole: .red)
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar":
            self.init(kind: .symbol("archivebox.fill"), colorRole: .yellow)
        case "db", "sqlite", "sqlite3":
            self.init(kind: .symbol("cylinder.fill"), colorRole: .blue)
        default:
            self = Self.syntaxDescriptor(for: fileURL)
        }
    }

    private init(kind: Kind, colorRole: ColorRole, prefersDarkBadgeText: Bool = false) {
        self.kind = kind
        self.colorRole = colorRole
        self.prefersDarkBadgeText = prefersDarkBadgeText
    }

    private static func syntaxDescriptor(for fileURL: URL) -> FileExplorerIconDescriptor {
        switch FilePreviewSyntaxLanguage(fileURL: fileURL) {
        case .swift: FileExplorerIconDescriptor(kind: .symbol("swift"), colorRole: .orange)
        case .javascript: FileExplorerIconDescriptor(kind: .badge("JS"), colorRole: .yellow, prefersDarkBadgeText: true)
        case .typescript: FileExplorerIconDescriptor(kind: .badge("TS"), colorRole: .blue)
        case .python: FileExplorerIconDescriptor(kind: .badge("PY"), colorRole: .blue)
        case .shell: FileExplorerIconDescriptor(kind: .symbol("terminal.fill"), colorRole: .green)
        case .json: FileExplorerIconDescriptor(kind: .symbol("curlybraces"), colorRole: .orange)
        case .html: FileExplorerIconDescriptor(kind: .symbol("chevron.left.forwardslash.chevron.right"), colorRole: .orange)
        case .css: FileExplorerIconDescriptor(kind: .badge("#"), colorRole: .blue)
        case .markdown: FileExplorerIconDescriptor(kind: .badge("MD"), colorRole: .green)
        case .rust: FileExplorerIconDescriptor(kind: .badge("RS"), colorRole: .orange)
        case .go: FileExplorerIconDescriptor(kind: .badge("GO"), colorRole: .cyan, prefersDarkBadgeText: true)
        case .cFamily: FileExplorerIconDescriptor(kind: .badge(Self.cFamilyBadge(for: fileURL)), colorRole: .blue)
        case .yaml: FileExplorerIconDescriptor(kind: .badge("Y"), colorRole: .red)
        case .toml: FileExplorerIconDescriptor(kind: .badge("T"), colorRole: .orange)
        case .sql: FileExplorerIconDescriptor(kind: .symbol("cylinder.fill"), colorRole: .blue)
        case .ruby: FileExplorerIconDescriptor(kind: .symbol("diamond.fill"), colorRole: .red)
        case .java: FileExplorerIconDescriptor(kind: .symbol("cup.and.saucer.fill"), colorRole: .orange)
        case .kotlin: FileExplorerIconDescriptor(kind: .badge("K"), colorRole: .purple)
        case .php: FileExplorerIconDescriptor(kind: .badge("PHP"), colorRole: .purple)
        case .configuration: FileExplorerIconDescriptor(kind: .symbol("gearshape.fill"), colorRole: .neutral)
        case .plainText: FileExplorerIconDescriptor(kind: .symbol("doc"), colorRole: .neutral)
        }
    }

    private static func cFamilyBadge(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "cc", "cpp", "cxx", "hpp": "C++"
        case "m", "mm": "OB"
        default: "C"
        }
    }

    private static let gitFileNames: Set<String> = [
        ".gitignore", ".gitattributes", ".gitmodules", ".gitkeep",
    ]

    private static let lockFileNames: Set<String> = [
        "bun.lock", "bun.lockb", "cargo.lock", "composer.lock", "gemfile.lock",
        "package-lock.json", "pnpm-lock.yaml", "poetry.lock", "yarn.lock",
    ]
}
