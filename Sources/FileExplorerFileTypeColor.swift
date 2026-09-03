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
    ///
    /// Every slot from 1 to 15 is spoken for, exactly once, and a test enforces
    /// that. Slot 0 is the only one left out: it is the terminal's own
    /// near-black, so anything painted with it disappears into the background.
    ///
    /// The split is deliberately finer than "code / not code", because the
    /// classes that dominate a source checkout are the ones worth telling
    /// apart. Lumping every language into one green and every `.json`,
    /// `Makefile` and `README` into one yellow leaves a repo looking like three
    /// colours no matter how many the palette has. So scripts separate from
    /// source, build files from plain config, prose from spreadsheets, and
    /// lockfiles from the caches nobody reads.
    enum Kind: CaseIterable {
        case secret, source, config, markup, data, document, generated
        case muted, archive, script, build, directory, media, symlink, office

        /// Index into the 16-colour ANSI palette.
        var paletteSlot: Int {
            switch self {
            case .secret: 1        // red            -- keys, certs, .env
            case .source: 2        // green          -- code
            case .config: 3        // yellow         -- json, yaml, toml, ini
            case .markup: 4        // blue           -- html, css, templates
            case .data: 5          // magenta        -- csv, parquet, sqlite
            case .document: 6      // cyan           -- md, rst, txt, README
            case .generated: 7     // white          -- lockfiles, generated code
            case .muted: 8         // bright black   -- build output, caches
            case .archive: 9       // bright red     -- zip, tar.gz, dmg
            case .script: 10       // bright green   -- sh, zsh, ps1  (`ex`)
            case .build: 11        // bright yellow  -- Makefile, Dockerfile
            case .directory: 12    // bright blue                     (`di`)
            case .media: 13        // bright magenta -- images, audio, fonts
            case .symlink: 14      // bright cyan                     (`ln`)
            case .office: 15       // bright white   -- pdf, docx, xlsx
            }
        }
    }

    // MARK: - Tables

    /// Extension -> class. The ~220 that actually turn up in a listing, not an
    /// exhaustive registry: anything unlisted returns nil and keeps the
    /// ordinary label colour, which is the right answer for a file nothing
    /// recognises.
    ///
    /// Compound suffixes are listed explicitly. Longest-match is applied at
    /// lookup, so `foo.tar.gz` is an archive rather than whatever `.gz` says.
    static let extensions: [String: Kind] = mapping([
        (.secret, """
            pem key crt cer der p12 pfx jks keystore gpg asc kbx pub \
            ppk netrc htpasswd
            """),
        (.source, """
            c h cc cpp cxx hpp hh rs go py pyi rb pl pm php java kt kts scala \
            swift m mm js jsx mjs cjs ts tsx vue svelte lua ex exs erl hs \
            clj cljs cljc ml mli fs fsx nim zig d dart r jl sql gleam v \
            el scm rkt asm s cs vb groovy tcl f90 f95 pas ada cob
            """),
        (.script, """
            sh bash zsh fish ksh csh ps1 psm1 bat cmd awk sed expect \
            applescript scpt
            """),
        (.config, """
            json json5 jsonc yaml yml toml ini cfg conf config properties env \
            xml plist tf tfvars hcl nix bazel bzl proto graphql gql \
            editorconfig gitignore gitattributes gitmodules dockerignore \
            npmrc nvmrc babelrc eslintrc prettierrc
            """),
        (.build, """
            gradle cmake mk make dockerfile bazelrc mill sbt cabal \
            podspec gemspec nuspec csproj vcxproj xcconfig entitlements
            """),
        (.generated, """
            lock sum snap pb generated d.ts min.js min.css \
            pb.go pb.cc pb.h
            """),
        (.markup, """
            html htm xhtml shtml css scss sass less styl \
            hbs mustache ejs pug jade haml erb njk liquid twig jinja jinja2
            """),
        (.data, """
            csv tsv psv parquet parq orc avro arrow feather \
            db sqlite sqlite3 duckdb mdb rdb dump \
            ndjson jsonl h5 hdf5 npy npz pkl pickle mat sav dta rds \
            ipynb geojson kml gpx
            """),
        (.document, """
            md markdown mdx adoc asciidoc rst tex org txt text log nfo \
            wiki creole pod rdoc
            """),
        (.office, """
            pdf epub mobi azw3 djvu doc docx odt rtf pages \
            xls xlsx ods numbers ppt pptx odp keynote
            """),
        (.archive, """
            7z bz2 gz lz4 lzma rar tar tgz txz tbz2 xz z zip zst jar war ear \
            deb rpm apk dmg iso pkg cab msi crx xpi \
            tar.gz tar.bz2 tar.xz tar.zst tar.lz4 tar.lzma
            """),
        (.media, """
            png jpg jpeg gif bmp webp avif tiff tif svg ico icns heic raw \
            psd ai sketch fig xcf \
            mp3 m4a flac wav ogg opus aac wma mid midi \
            mp4 mkv webm mov avi wmv flv m4v mpg mpeg 3gp \
            ttf otf woff woff2 eot blend fbx obj stl glb gltf usdz
            """),
        (.muted, """
            bak old orig rej tmp temp swp swo swn pyc pyo pyd o a so dylib \
            dll lib exp ilk pdb class cache map dSYM nib xcuserstate \
            DS_Store localized
            """),
    ])

    /// Whole filenames that carry more meaning than their extension does --
    /// `Makefile` has none at all, and a README is prose wherever it sits.
    static let filenames: [String: Kind] = mapping([
        (.build, """
            Makefile makefile GNUmakefile Dockerfile Containerfile Vagrantfile \
            Justfile justfile Brewfile Rakefile Gemfile Procfile Taskfile \
            CMakeLists.txt meson.build BUILD WORKSPACE \
            package.json tsconfig.json Cargo.toml go.mod pyproject.toml \
            requirements.txt setup.py setup.cfg flake.nix shell.nix default.nix
            """),
        (.generated, """
            package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock \
            Cargo.lock go.sum Gemfile.lock poetry.lock Pipfile.lock \
            composer.lock flake.lock uv.lock
            """),
        (.secret, """
            .env .env.local .env.production .env.development .envrc \
            id_rsa id_ed25519 id_ecdsa known_hosts authorized_keys \
            credentials .netrc .npmrc.local secrets.yaml secrets.yml
            """),
        (.document, """
            README README.md README.txt LICENSE LICENCE COPYING CHANGELOG \
            CHANGELOG.md CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md \
            AUTHORS NOTICE TODO CLAUDE.md AGENTS.md
            """),
    ])

    /// Directory name -> class. Matched EXACTLY, not as a suffix, so ordinary
    /// project folders can be listed without `lib` also repainting `zlib`.
    static let directories: [String: Kind] = mapping([
        (.source, """
            src source lib libs app apps pkg pkgs internal cmd crates \
            packages components modules hooks services handlers models
            """),
        (.script, "bin scripts sbin tools"),
        (.document, "docs doc documentation man manual guides adr rfcs"),
        (.data, "data datasets fixtures seeds migrations schema db database"),
        (.media, "assets static public images img media icons fonts audio video"),
        (.config, "config .config conf etc settings deploy infra terraform"),
        (.markup, "templates views layouts partials styles stylesheets css"),
        (.secret, "secrets .ssh certs keys credentials"),
        (.generated, """
            .git .github .gitlab .circleci .husky .idea .vscode .vs \
            generated gen proto-gen
            """),
        (.archive, "archive archives backup backups"),
        (.muted, """
            node_modules __pycache__ .pytest_cache .mypy_cache .ruff_cache \
            .parcel-cache .turbo .gradle .terraform .tox .eggs .venv venv \
            virtualenv .next .nuxt .svelte-kit site-packages DerivedData \
            CMakeFiles target dist build out coverage htmlcov Pods vendor \
            tmp temp .cache .DS_Store obj bin.out
            """),
    ])

    /// Flattens the whitespace-separated groups above into one lookup.
    ///
    /// Takes an ORDERED array rather than a `[Kind: String]` dictionary on
    /// purpose. A dictionary literal has unspecified iteration order, so a name
    /// listed under two classes -- `obj` is both a 3D model and a linker object
    /// file -- would resolve to whichever class happened to be visited last,
    /// and could differ between launches. Here a duplicate is a programmer
    /// error and trips immediately.
    private static func mapping(_ groups: [(Kind, String)]) -> [String: Kind] {
        var out: [String: Kind] = [:]
        for (kind, names) in groups {
            for name in names.split(whereSeparator: \.isWhitespace) {
                let key = String(name)
                assert(out[key] == nil, "\(key) is listed under two classes")
                out[key] = kind
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
