import Foundation
import CmuxNextSettings

/// A project's own favicon for its picker badge (`project.icon {cwd}`): the New Tab page's folder
/// strip and the composer's folder menu draw it in place of the letter tile. The page reads no
/// file (CSP `img-src data:`), so the host looks for a few well-known icon files in the folder and
/// answers a small data URL.
///
/// Never a read inside a privacy-protected folder (LAUNCH-NO-TCC-PROMPTS): the folder and every
/// candidate go through `ChatRootValidator` first, which checks the spelling, then resolves links
/// with `readlink` only, and refuses `/`, the home folder, other volumes and the protected folders
/// of the one list (cmux-tui/crates/acpmux/data/protected-folders.json). The disk matches names
/// more loosely than a spelling check (`Documentſ`, `/System/Volumes/Data/Users/…`), so each path,
/// before and after its links are resolved, must also reach no protected folder by identity
/// (`reachesProtectedFolder`, `lstat` only). Resolving can lstat or readlink through a protected
/// folder, which raises no prompt; a refused path is never stat'ed for its contents, opened or read,
/// so a favicon linked into Documents is no icon. One linked elsewhere in the project is read at its
/// target.
nonisolated struct AgentPaneProjectIcon: Sendable {
    /// Larger files are skipped: a tile is 20pt, and the answer crosses the bridge as base64.
    static let maximumBytes = 64 * 1024
    /// A package.json is read whole up to this size: cut short it is no JSON, and some (an editor
    /// extension's) run well past an icon's limit.
    static let maximumManifestBytes = 1024 * 1024
    /// Best first: a vector or a 180px touch icon draws sharper in the tile than a 16px `.ico`.
    static let names = ["favicon.svg", "icon.svg", "apple-touch-icon.png", "favicon.png", "icon.png", "favicon.ico"]
    /// The folder itself and where web frameworks keep their icons (Next.js `app/`, Vite and
    /// Next.js `public/`, SvelteKit `static/`).
    static let folders = ["", "public", "static", "app", "src/app", "assets"]
    /// An icon the repository picked for cmux wins over any web favicon.
    static let chosen = [".cmux/icon.svg", ".cmux/icon.png"]
    /// Logos, after the favicons: a logo is often a wordmark that reads poorly in a square tile.
    static let logos = ["logo.svg", "logo.png", "assets/logo.svg", "assets/logo.png"]
    /// Where Xcode projects keep their asset catalog; `<folder name>/Assets.xcassets` is the
    /// app target's folder in a new Xcode project.
    static let assetCatalogs = ["Assets.xcassets", "Resources/Assets.xcassets"]

    /// A regular file's size and modification date, or nil (the cache key with its path).
    var stat: @Sendable (String) -> File?
    var read: @Sendable (String) -> Data?
    /// A manifest's bytes, up to `maximumManifestBytes`, or nil.
    var readManifest: @Sendable (String) -> Data?
    /// A folder's entry names, or nil (the AppIcon set's images).
    var list: @Sendable (String) -> [String]?
    private var validator: ChatRootValidator

    struct File: Equatable, Sendable {
        var size: Int
        var modified: Date
    }

    init(home: String = NSHomeDirectory()) {
        validator = ChatRootValidator(home: home)
        stat = { path in
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return nil }
            return File(size: size, modified: values.contentModificationDate ?? .distantPast)
        }
        read = { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: AgentPaneProjectIcon.maximumBytes + 1)
        }
        readManifest = { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: AgentPaneProjectIcon.maximumManifestBytes)
        }
        list = { path in try? FileManager.default.contentsOfDirectory(atPath: path) }
    }

    /// Every path looked for in `folder`, best first.
    static func candidates(in folder: String) -> [String] {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let favicons = names.flatMap { name in folders.map { sub in sub.isEmpty ? "\(base)/\(name)" : "\(base)/\(sub)/\(name)" } }
        return chosen.map { "\(base)/\($0)" } + favicons + logos.map { "\(base)/\($0)" }
    }

    /// The AppIcon sets an Xcode project in `folder` may have.
    static func appIconSets(in folder: String) -> [String] {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let name = (base as NSString).lastPathComponent
        return (assetCatalogs + ["\(name)/Assets.xcassets"]).map { "\(base)/\($0)/AppIcon.appiconset" }
    }

    /// A copy for one answer: each folder on the way to its paths is checked once
    /// (``ChatRootValidator/batch()``), not once per candidate file.
    func batched() -> AgentPaneProjectIcon {
        var copy = self
        copy.validator = validator.batch()
        return copy
    }

    /// A copy that checks through `other`'s batch when both guard the same home, so one answer's
    /// walks share their lookups; otherwise a batch of its own.
    func batched(sharing other: AgentPaneProjectIcon) -> AgentPaneProjectIcon {
        guard validator.home == other.validator.home else { return batched() }
        var copy = self
        copy.validator = other.validator
        return copy
    }

    /// True when `path` may be looked at: refused neither by its spelling nor by what it reaches.
    func allows(_ path: String) -> Bool {
        validator.refusal(path) == nil && !validator.reachesProtectedFolder(path)
    }

    /// The candidates in `folder` that may be read, are regular files and are small enough, best
    /// first, each at its resolved path (a favicon linked within the project is read at its target).
    func files(in folder: String) -> [(path: String, file: File)] {
        guard folder.hasPrefix("/"), allows(folder) else { return [] }
        var found: [(path: String, file: File)] = []
        for candidate in Self.candidates(in: folder) where allows(candidate) {
            // `realpath` reads only link entries and keeps `/private`, unlike `resolvingSymlinksInPath`.
            guard let resolved = Self.realPath(candidate), resolved == candidate || allows(resolved),
                  let file = stat(resolved), file.size > 0, file.size <= Self.maximumBytes else { continue }
            found.append((resolved, file))
        }
        if let appIcon = appIcon(in: folder) { found.append(appIcon) }
        return found
    }

    /// `path` resolved, when it and its target may be looked at and it is a regular file.
    private func regularFile(_ path: String) -> String? {
        guard allows(path), let resolved = Self.realPath(path), resolved == path || allows(resolved),
              stat(resolved) != nil else { return nil }
        return resolved
    }

    /// The largest PNG of the first AppIcon set that has one small enough: the sharpest that still
    /// crosses the bridge.
    func appIcon(in folder: String) -> (path: String, file: File)? {
        for set in Self.appIconSets(in: folder) where allows(set) {
            guard let entries = list(set) else { continue }
            var best: (path: String, file: File)?
            for entry in entries.sorted() where entry.lowercased().hasSuffix(".png") {
                let candidate = set + "/" + entry
                guard allows(candidate), let resolved = Self.realPath(candidate), resolved == candidate || allows(resolved),
                      let file = stat(resolved), file.size > 0, file.size <= Self.maximumBytes,
                      file.size > (best?.file.size ?? 0) else { continue }
                best = (resolved, file)
            }
            if let best { return best }
        }
        return nil
    }

    /// The web, desktop and mobile frameworks a package.json can name, most specific first: a
    /// meta-framework over its UI library (Next.js is React, Nuxt is Vue), a desktop or mobile shell
    /// over the UI library inside it (an Electron app built with React shows Electron), a UI library
    /// over its bundler (a React app built with Vite shows React), so the mark says what kind of app
    /// it is. A bare React Native app (no `expo`) shows React: the Expo mark is Expo's own.
    static let packageFrameworks: [(glyph: String, packages: [String])] = [
        ("next", ["next"]),
        ("nuxt", ["nuxt", "nuxt3"]),
        ("remix", ["@remix-run/react", "@remix-run/node", "@react-router/dev"]),
        ("astro", ["astro"]),
        ("expo", ["expo"]),
        ("electron", ["electron"]),
        ("tauri", ["@tauri-apps/api", "@tauri-apps/cli"]),
        ("svelte", ["@sveltejs/kit", "svelte"]),
        ("angular", ["@angular/core"]),
        ("vue", ["vue"]),
        ("react", ["react"]),
        ("vite", ["vite"]),
    ]

    /// The package names a package.json depends on, in any of its dependency lists; empty for a
    /// manifest that is not JSON.
    static func dependencies(of manifest: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else { return [] }
        var names = Set<String>()
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            if let list = object[key] as? [String: Any] { names.formUnion(list.keys) }
        }
        return names
    }

    /// A framework or language mark from the project's manifest, for a project with no icon file:
    /// one of `PROJECT_GLYPHS` (webviews projectIcon.ts); nil for none.
    func glyph(in folder: String) -> String? {
        guard folder.hasPrefix("/"), allows(folder) else { return nil }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let has = { (name: String) -> Bool in regularFile(base + "/" + name) != nil }
        let text = { (name: String) -> String in
            regularFile(base + "/" + name).flatMap(read).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        if has("Package.swift") || hasXcodeProject(base) { return "swift" }
        if let package = regularFile(base + "/package.json") {
            let names = readManifest(package).map(Self.dependencies(of:)) ?? []
            if let framework = Self.packageFrameworks.first(where: { !names.isDisjoint(with: $0.packages) }) {
                return framework.glyph
            }
            if has("src-tauri/Cargo.toml") { return "tauri" }
            if has("Cargo.toml") { return "rust" }
            if has("bun.lock") || has("bun.lockb") { return "bun" }
            if has("tsconfig.json") || names.contains("typescript") { return "typescript" }
            return "node"
        }
        if has("Cargo.toml") { return "rust" }
        if has("deno.json") || has("deno.jsonc") { return "deno" }
        if has("pubspec.yaml") { return text("pubspec.yaml").contains("flutter:") ? "flutter" : "dart" }
        if has("pyproject.toml") || has("setup.py") || has("requirements.txt") { return "python" }
        if has("go.mod") { return "go" }
        if has("Gemfile") { return "ruby" }
        if has("build.zig") { return "zig" }
        if has("mix.exs") { return "elixir" }
        if has("composer.json") { return "php" }
        if has("build.gradle.kts") || has("settings.gradle.kts") { return "kotlin" }
        if has("pom.xml") || has("build.gradle") { return "java" }
        if has("CMakeLists.txt") { return "cpp" }
        return nil
    }

    /// True when the folder holds an Xcode project or workspace (an app with no Package.swift).
    private func hasXcodeProject(_ base: String) -> Bool {
        guard let entries = list(base) else { return false }
        return entries.contains { name in
            (name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")) && allows(base + "/" + name)
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The data URL of an image file, typed by its bytes; nil for anything that is not one.
    func dataURL(_ path: String) -> String? {
        guard let data = read(path), !data.isEmpty, data.count <= Self.maximumBytes, let type = Self.imageType(data) else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// The icon of the project at `folder`, uncached: the first candidate that is an image.
    func icon(in folder: String) -> String? {
        files(in: folder).lazy.compactMap { dataURL($0.path) }.first
    }

    static func imageType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        // An SVG as an <img> runs no script; its root element must show up front.
        // Decoded leniently: the first kilobyte can end inside a character.
        if String(decoding: data.prefix(1024), as: UTF8.self).lowercased().contains("<svg") { return "image/svg+xml" }
        return nil
    }
}

/// The icons the pickers asked for, read off the main actor and kept by file path and
/// modification date: a project's icon is read once until the file changes.
actor AgentPaneProjectIcons {
    static let shared = AgentPaneProjectIcons(reader: AgentPaneProjectIcon())

    private let reader: AgentPaneProjectIcon
    private let repos: AgentPaneProjectRepoReader
    private let avatars: AgentPaneOwnerAvatars
    private var cache: [String: (file: AgentPaneProjectIcon.File, url: String?)] = [:]

    init(reader: AgentPaneProjectIcon, repos: AgentPaneProjectRepoReader = .shared, avatars: AgentPaneOwnerAvatars = .shared) {
        self.reader = reader
        self.repos = repos
        self.avatars = avatars
    }

    /// The `project.icon` answer: the GitHub owner's avatar (a user's or an organization's), else an
    /// icon file in the folder, else in its repository's main checkout (a worktree whose icon is not
    /// checked in yet, or a folder inside the repository); and the manifest's framework or language
    /// mark, which the page draws only without an image. All nil leave the page's folder. The avatar
    /// comes first so every clone and worktree of one GitHub repository wears the same picture (Leo
    /// 2026-10-21: "why are the project icons not showing up for SOME of the cmux...? only one has
    /// my github icon?").
    func answer(for folder: String) async -> (src: String?, glyph: String?) {
        let reader = self.reader.batched()
        let repos = self.repos.batched(sharing: reader)
        let repo = reader.allows(folder) ? repos.repo(for: folder) : nil
        let root = repo.map(\.root).flatMap { $0 == folder ? nil : $0 }
        let glyph = reader.glyph(in: folder) ?? root.flatMap(reader.glyph(in:))
        if let owner = repo?.github?.split(separator: "/").first.map(String.init),
           let avatar = await avatars.avatar(for: owner) { return (avatar, glyph) }
        return (icon(for: folder, reader: reader) ?? root.flatMap({ icon(for: $0, reader: reader) }), glyph)
    }

    /// The first candidate that is an image; a cached answer stands until its file changes.
    func icon(for folder: String) -> String? {
        icon(for: folder, reader: reader.batched())
    }

    private func icon(for folder: String, reader: AgentPaneProjectIcon) -> String? {
        for picked in reader.files(in: folder) {
            if let known = cache[picked.path], known.file == picked.file {
                if let url = known.url { return url }
                continue
            }
            let url = reader.dataURL(picked.path)
            if cache.count >= 512 { cache.removeAll() }
            cache[picked.path] = (picked.file, url)
            if let url { return url }
        }
        return nil
    }
}
