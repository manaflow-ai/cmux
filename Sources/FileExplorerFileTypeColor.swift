import AppKit
import CMUXMobileCore
import CmuxFoundation
import Foundation

/// Colours a file explorer row by what the file *is*, from the terminal's own
/// 16 ANSI slots.
///
/// The tree currently paints every name `.labelColor` and tints every icon with
/// one colour per style, so a `.rs`, a `node_modules` and a 2 GB `.parquet` are
/// visually identical. `ls`, `eza` and every other listing tool one pane over
/// colour all three differently.
///
/// Reading the colours out of ``TerminalTheme/palette`` rather than hardcoding
/// them is the point: the sidebar then tracks whatever Ghostty theme is
/// selected, in light and dark, with no second palette to keep in sync and
/// nothing to configure. Someone on Catppuccin gets Catppuccin; someone on an
/// ANSI-only scheme gets theirs.
///
/// Off by default. `fileExplorer.colorByFileType` turns it on.
enum FileExplorerFileTypeColor {

    // MARK: - Classes

    /// What a row is, mapped to the ANSI slot that carries the same meaning in
    /// a terminal listing: directories take the slot `ls` uses for `di`,
    /// executables the one it uses for `ex`, and so on.
    enum Kind: CaseIterable {
        case directory, symlink, executable, archive, media, document
        case source, config, markup, data, muted, plain

        /// Index into the 16-colour ANSI palette. Slot 0 is deliberately unused:
        /// it is the terminal's own near-black and would be invisible.
        var paletteSlot: Int {
            switch self {
            case .directory: 12   // blue, bright  -- `di`
            case .symlink: 14     // cyan, bright  -- `ln`
            case .executable: 10  // green, bright -- `ex`
            case .archive: 9      // red, bright   -- `*.tar.gz` and friends
            case .media: 13       // magenta, bright
            case .document: 11    // yellow, bright
            case .source: 2       // green
            case .config: 3       // yellow
            case .markup: 4       // blue
            case .data: 6         // cyan
            case .muted: 8        // black, bright -- build output, caches
            case .plain: 15       // white, bright -- the fallback
            }
        }
    }

    // MARK: - Tables

    /// Extension -> class. The ~180 that actually turn up in a listing, not an
    /// exhaustive registry: anything unlisted falls back to `.plain`, which is
    /// the correct answer for a file nothing recognises.
    ///
    /// Compound suffixes are listed explicitly. Longest-match is applied at
    /// lookup, so `foo.tar.gz` is an archive rather than whatever `.gz` says.
    static let extensions: [String: Kind] = mapping([
        .archive: """
            7z bz2 gz lz4 lzma rar tar tgz txz tbz2 xz z zip zst jar war ear \
            deb rpm apk dmg iso pkg cab msi crx \
            tar.gz tar.bz2 tar.xz tar.zst tar.lz4 tar.lzma
            """,
        .media: """
            png jpg jpeg gif bmp webp avif tiff tif svg ico heic raw psd ai \
            mp3 m4a flac wav ogg opus aac wma mid \
            mp4 mkv webm mov avi wmv flv m4v mpg mpeg 3gp \
            ttf otf woff woff2 eot blend fbx obj stl glb gltf
            """,
        .document: """
            pdf epub mobi azw3 djvu doc docx odt rtf xls xlsx ods \
            ppt pptx odp md markdown adoc rst tex org txt log
            """,
        .data: """
            csv tsv psv parquet parq orc avro arrow feather \
            db sqlite sqlite3 duckdb mdb rdb dump \
            ndjson jsonl h5 hdf5 npy npz pkl pickle mat sav dta rds \
            ipynb geojson kml gpx
            """,
        .source: """
            c h cc cpp cxx hpp hh rs go py pyi rb pl pm php java kt kts scala \
            swift m mm js jsx mjs cjs ts tsx vue svelte lua ex exs erl hs \
            clj cljs cljc ml mli fs fsx nim zig d dart r jl sql gleam v \
            sh bash zsh fish ps1 bat cmd awk sed vim el scm rkt asm s
            """,
        .config: """
            json json5 jsonc yaml yml toml ini cfg conf config properties env \
            xml plist lock sum mod gradle cmake mk make dockerfile \
            tf tfvars hcl nix bazel bzl proto graphql gql editorconfig \
            gitignore gitattributes gitmodules npmrc nvmrc babelrc eslintrc \
            prettierrc dockerignore
            """,
        .markup: """
            html htm xhtml shtml css scss sass less styl \
            hbs mustache ejs pug jade haml erb njk liquid twig
            """,
        .muted: """
            bak old orig rej tmp temp swp swo swn pyc pyo pyd o a so dylib dll \
            class cache map min dSYM
            """,
    ])

    /// Whole filenames that carry more meaning than their extension does --
    /// `Makefile` has none at all, and a README is a document wherever it sits.
    static let filenames: [String: Kind] = mapping([
        .config: """
            Makefile makefile GNUmakefile Dockerfile Containerfile Vagrantfile \
            Justfile justfile Brewfile Rakefile Gemfile Procfile CMakeLists.txt \
            package.json tsconfig.json Cargo.toml go.mod pyproject.toml \
            requirements.txt setup.py setup.cfg flake.nix shell.nix default.nix
            """,
        .document: """
            README README.md README.txt LICENSE LICENCE COPYING CHANGELOG \
            CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md AUTHORS NOTICE \
            CLAUDE.md AGENTS.md
            """,
    ])

    /// Directory names worth separating from the source you are looking for.
    /// Deliberately short: only build output, caches and tool metadata, whose
    /// names are unambiguous. Generic names (`src`, `lib`, `app`, `bin`) are
    /// left alone -- their meaning is project-specific and guessing wrong is
    /// worse than leaving them the ordinary directory colour.
    static let directories: [String: Kind] = mapping([
        .muted: """
            node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache \
            .parcel-cache .turbo .gradle .terraform .tox .eggs .venv venv \
            .next .nuxt .svelte-kit site-packages DerivedData CMakeFiles \
            target dist build out coverage htmlcov Pods vendor
            """,
        .config: ".git .github .gitlab .circleci .husky .idea .vscode",
    ])

    private static func mapping(_ groups: [Kind: String]) -> [String: Kind] {
        var out: [String: Kind] = [:]
        for (kind, names) in groups {
            for name in names.split(whereSeparator: \.isWhitespace) {
                out[String(name)] = kind
            }
        }
        return out
    }

    // MARK: - Classification

    /// What class `name` belongs to, or `nil` when nothing claims it and the
    /// caller should leave the row at its ordinary colour.
    ///
    /// Directories resolve by name and never fall through to the extension
    /// table: a folder called `assets.old` is a folder, not a backup file.
    static func kind(forName name: String, isDirectory: Bool, isSymlink: Bool = false) -> Kind? {
        if isSymlink { return .symlink }
        if isDirectory { return directories[name] ?? .directory }
        if let byName = filenames[name] { return byName }

        // Longest suffix first, so `.tar.gz` beats `.gz`.
        let lowered = name.lowercased()
        var index = lowered.startIndex
        while let dot = lowered[index...].firstIndex(of: ".") {
            let suffix = String(lowered[lowered.index(after: dot)...])
            if let kind = extensions[suffix] { return kind }
            index = lowered.index(after: dot)
        }
        return nil
    }

    // MARK: - Palette

    /// The live terminal palette, cached because `configure(with:)` runs once
    /// per visible row on every reload and re-reading the Ghostty config there
    /// would be absurd. Invalidated by the same notifications the agent-chat
    /// theme sync listens to.
    @MainActor
    private static var cachedPalette: [NSColor]?
    @MainActor
    private static var observersInstalled = false

    @MainActor
    static func invalidatePaletteCache() {
        cachedPalette = nil
    }

    @MainActor
    private static func palette() -> [NSColor]? {
        installObserversIfNeeded()
        if let cachedPalette { return cachedPalette }
        let config = GhosttyConfig.loadForCmux(
            globalFontMagnificationPercent: GlobalFontMagnification.storedPercent
        )
        let hexes = TerminalTheme(ghosttyConfig: config).palette
        guard hexes.count >= TerminalTheme.paletteCount else { return nil }
        let resolved = hexes.prefix(TerminalTheme.paletteCount).compactMap { NSColor(hex: $0) }
        // All sixteen or none: a partial palette would silently paint some
        // classes with another class's colour.
        guard resolved.count == TerminalTheme.paletteCount else { return nil }
        cachedPalette = resolved
        return resolved
    }

    @MainActor
    private static func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        for name in [Notification.Name.ghosttyConfigDidReload,
                     .ghosttyDefaultBackgroundDidChange] {
            _ = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { cachedPalette = nil }
            }
        }
    }

    // MARK: - Entry point

    /// Whether the tree should colour by file type. Off unless asked for, so
    /// nobody's sidebar changes appearance on upgrade.
    /// UserDefaults key behind `fileExplorer.colorByFileType`.
    static let defaultsKey = "fileExplorerColorByFileType"

    @MainActor
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// The colour for a row, or `nil` to leave it alone -- which happens when
    /// the feature is off, the name is unrecognised, or the terminal palette
    /// could not be resolved.
    @MainActor
    static func color(forName name: String, isDirectory: Bool, isSymlink: Bool = false) -> NSColor? {
        guard isEnabled,
              let kind = kind(forName: name, isDirectory: isDirectory, isSymlink: isSymlink),
              let palette = palette()
        else { return nil }
        return palette[kind.paletteSlot]
    }
}
