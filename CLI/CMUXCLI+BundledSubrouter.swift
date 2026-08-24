import Foundation
import Darwin

// The bundled subrouter binary: the app ships Resources/bin/subrouter.gz
// (built from the pinned submodule by scripts/build-subrouter.sh); the CLI
// extracts it once per bundled version into Application Support and routes
// `cmux sr …` / unknown `cmux subrouter …` verbs to it. A user-installed
// sr on PATH always wins, so bundling only changes machines with no sr.
extension CMUXCLI {
    private static let bundledSubrouterInstallMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let bundledSubrouterLastUsedMarker = ".cmux-last-used"

    /// The root for extracted subrouter binaries. Each app/tag gets its own
    /// immutable child so concurrent cmux builds never replace one another's
    /// executable or fingerprint.
    private static var bundledSubrouterInstallRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux/bin", isDirectory: true)
    }

    /// The directory extracted subrouter binaries for this app identity live
    /// in. ``CMUX_TAG`` is preferred for tagged builds; a bundle id keeps
    /// stable and production app installs separate when no tag is present.
    static var bundledSubrouterInstallDirectory: URL {
        bundledSubrouterInstallRoot.appendingPathComponent(
            bundledSubrouterInstallScope(),
            isDirectory: true
        )
    }

    private static var bundledSubrouterManagedMarker: URL {
        bundledSubrouterInstallDirectory.appendingPathComponent(".cmux-managed")
    }

    private static func bundledSubrouterInstallScope() -> String {
        let environment = ProcessInfo.processInfo.environment
        let raw = [
            environment["CMUX_TAG"],
            environment["CMUX_BUNDLE_ID"],
            Bundle.main.bundleIdentifier,
            "stable",
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "stable"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = raw.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var scope = String(mapped).replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        scope = scope.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if scope.isEmpty { scope = "stable" }
        return "scope-" + String(scope.prefix(96))
    }

    /// The compressed binary inside the app bundle, located relative to the
    /// bundled CLI (`<app>/Contents/Resources/bin/cmux`), or `nil` when the
    /// CLI runs outside an app bundle that ships one.
    static func bundledSubrouterArchivePath() -> String? {
        var candidates: [String] = []
        if let bundledResource = Bundle.main.url(
            forResource: "subrouter",
            withExtension: "gz",
            subdirectory: "bin"
        ) {
            candidates.append(bundledResource.path)
        }
        if let bundled = ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"], !bundled.isEmpty {
            candidates.append(bundled)
        }
        candidates.append(CommandLine.arguments[0])
        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
            let archive = resolved.deletingLastPathComponent()
                .appendingPathComponent("subrouter.gz").path
            if FileManager.default.fileExists(atPath: archive) {
                return archive
            }
        }
        return nil
    }

    /// Extracts the bundled binary (once per bundled version) and returns
    /// the executable path of the requested persona (`sr` or `subrouter`),
    /// or `nil` when nothing is bundled or extraction fails.
    ///
    /// Freshness is keyed on the archive's size+mtime fingerprint rather
    /// than a content hash: the archive only changes when the app updates.
    static func extractedSubrouterBinary(persona: String = "sr") -> String? {
        guard let archivePath = bundledSubrouterArchivePath() else { return nil }
        let fileManager = FileManager.default
        let installDir = bundledSubrouterInstallDirectory
        pruneBundledSubrouterInstallDirectories(excluding: installDir)
        let binaryURL = installDir.appendingPathComponent("subrouter")
        let personaURL = installDir.appendingPathComponent(persona)
        let fingerprintURL = installDir.appendingPathComponent(".subrouter.fingerprint")

        guard let attributes = try? fileManager.attributesOfItem(atPath: archivePath),
              let size = attributes[.size] as? Int64,
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        let fingerprint = "\(size)-\(Int(modified.timeIntervalSince1970))"

        let current = (try? String(contentsOf: fingerprintURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current != fingerprint || !fileManager.isExecutableFile(atPath: binaryURL.path) {
            do {
                try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
                // Per-process staging name: two concurrent `cmux sr` runs
                // must never interleave writes into one staging file, or the
                // extracted binary is corrupt.
                let staging = installDir.appendingPathComponent(
                    ".subrouter.extracting.\(ProcessInfo.processInfo.processIdentifier)"
                )
                defer { try? fileManager.removeItem(at: staging) }
                // gunzip -c preserves the embedded ad-hoc code signature.
                let gunzip = Process()
                gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                gunzip.arguments = ["-c", archivePath]
                fileManager.createFile(atPath: staging.path, contents: nil)
                gunzip.standardOutput = try FileHandle(forWritingTo: staging)
                try gunzip.run()
                gunzip.waitUntilExit()
                guard gunzip.terminationStatus == 0 else { return nil }
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
                // rename(2) atomically replaces any binary a concurrent
                // extraction just installed; both stagings hold the same
                // bundled version, so last-writer-wins is safe.
                guard rename(staging.path, binaryURL.path) == 0 else { return nil }
                try fingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }

        if persona != "subrouter" {
            // The binary dispatches on argv[0]; a symlink provides the name.
            if (try? fileManager.destinationOfSymbolicLink(atPath: personaURL.path)) != "subrouter" {
                _ = try? fileManager.removeItem(at: personaURL)
                try? fileManager.createSymbolicLink(
                    atPath: personaURL.path,
                    withDestinationPath: "subrouter"
                )
            }
            guard fileManager.isExecutableFile(atPath: personaURL.path) else { return nil }
            markBundledSubrouterUse(in: installDir)
            return personaURL.path
        }
        markBundledSubrouterUse(in: installDir)
        return binaryURL.path
    }

    /// Removes abandoned tag-scoped extractions after a generous inactivity
    /// window. The current scope and scopes with an active extraction staging
    /// file are always retained; the binary can be rebuilt from the pinned
    /// archive if an old scope is needed again.
    private static func pruneBundledSubrouterInstallDirectories(excluding current: URL) {
        let root = bundledSubrouterInstallRoot
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-bundledSubrouterInstallMaxAge)
        for entry in entries where entry.lastPathComponent.hasPrefix("scope-") {
            guard entry.standardizedFileURL != current.standardizedFileURL,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = bundledSubrouterLastUsedDate(for: entry, fileManager: fileManager),
                  modified < cutoff else { continue }
            let isExtracting = (try? fileManager.contentsOfDirectory(atPath: entry.path))?
                .contains { $0.hasPrefix(".subrouter.extracting.") } == true
            guard !isExtracting else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func markBundledSubrouterUse(in directory: URL) {
        let marker = directory.appendingPathComponent(bundledSubrouterLastUsedMarker)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: marker.path) {
            _ = fileManager.createFile(atPath: marker.path, contents: Data())
        }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: marker.path
        )
    }

    private static func bundledSubrouterLastUsedDate(
        for directory: URL,
        fileManager: FileManager
    ) -> Date? {
        let marker = directory.appendingPathComponent(bundledSubrouterLastUsedMarker)
        let path = fileManager.fileExists(atPath: marker.path) ? marker.path : directory.path
        return (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Installs the bundled binary into `~/bin` as `subrouter` + `sr`
    /// symlinks for an untagged app (the layout the official installer
    /// produces). Tagged builds return their private scoped path instead and
    /// never write global links, so one dev build cannot repoint another.
    /// Returns the `sr` path, or `nil` when nothing is bundled.
    func installBundledSubrouterIntoHomeBin() -> String? {
        guard let extracted = Self.extractedSubrouterBinary(persona: "subrouter") else {
            return nil
        }
        if Self.isTaggedBuild {
            return Self.extractedSubrouterBinary(persona: "sr")
        }
        let fileManager = FileManager.default
        let homeBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin", isDirectory: true)
        do {
            try fileManager.createDirectory(at: homeBin, withIntermediateDirectories: true)
            var createdManagedLink = false
            for name in ["subrouter", "sr"] {
                let link = homeBin.appendingPathComponent(name)
                // attributesOfItem does not traverse symlinks: any existing
                // entry — a user install, or even a broken symlink — is the
                // user's and must never be replaced.
                if (try? fileManager.attributesOfItem(atPath: link.path)) != nil { continue }
                try fileManager.createSymbolicLink(
                    atPath: link.path,
                    withDestinationPath: extracted
                )
                createdManagedLink = true
            }
            if createdManagedLink {
                try "managed\n".write(
                    to: Self.bundledSubrouterManagedMarker,
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            return nil
        }
        let sr = homeBin.appendingPathComponent("sr").path
        return fileManager.isExecutableFile(atPath: sr) ? sr : nil
    }

    private static var isTaggedBuild: Bool {
        guard let tag = ProcessInfo.processInfo.environment["CMUX_TAG"] else { return false }
        return !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Resolves sr like `resolveSubrouterBinary()`, but when the resolved
    /// path is — or symlinks into — the managed extraction directory (the
    /// layout the welcome flow may install into `~/bin`), refreshes the
    /// extraction first. Without this, a managed `~/bin/sr` shortcut would
    /// pin users to the binary extracted at first install and ignore every
    /// newer bundled version an app update ships.
    func resolveSubrouterBinaryRefreshingManagedInstall() -> String? {
        guard let resolved = resolveSubrouterBinary() else { return nil }
        let target = URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path
        let managedDir = Self.bundledSubrouterInstallDirectory
            .resolvingSymlinksInPath().path
        let managedRoot = Self.bundledSubrouterInstallRoot
            .resolvingSymlinksInPath().path
        let homeBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin", isDirectory: true)
            .resolvingSymlinksInPath().path
        if FileManager.default.fileExists(atPath: Self.bundledSubrouterManagedMarker.path),
           resolved.hasPrefix(homeBin + "/"),
           let refreshed = Self.extractedSubrouterBinary(persona: "sr") {
            // `sr install-daemon` may replace the managed `subrouter` link
            // with a regular file while leaving the marker. Prefer the fresh
            // app extraction for that known managed installation.
            return refreshed
        }
        if target == managedDir || target.hasPrefix(managedDir + "/") {
            // Best-effort: a failed refresh leaves the previous (still
            // executable) extraction in place.
            return Self.extractedSubrouterBinary(persona: "sr") ?? resolved
        }
        if target.hasPrefix(managedRoot + "/") {
            // A global ~/bin/sr link may still point at another tagged build's
            // managed directory. Prefer this process's scoped extraction so a
            // stable app and a tagged build cannot execute one another's sr.
            return Self.extractedSubrouterBinary(persona: "sr") ?? resolved
        }
        return resolved
    }

    /// Replaces this process with the subrouter binary running `arguments`
    /// under the given persona. Prefers a user-installed sr from PATH, then
    /// the bundled binary. Only returns on failure.
    func execSubrouter(persona: String, arguments: [String]) throws -> Never {
        let executable = resolveSubrouterBinaryRefreshingManagedInstall()
            ?? Self.extractedSubrouterBinary(persona: persona)
        guard let executable else {
            throw CLIError(message: """
                subrouter is not installed and this cmux build does not bundle it.
                Install it explicitly from github.com/manaflow-ai/subrouter, then retry.
                """)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(persona)]
        argv.append(contentsOf: arguments.map { strdup($0) })
        argv.append(nil)
        let execErrno: Int32 = argv.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return EINVAL }
            return withEnvironmentCStringArray(Self.scrubbedSubrouterEnvironment()) { environment in
                execve(executable, baseAddress, environment)
                return errno
            }
        }
        for pointer in argv.compactMap({ $0 }) {
            free(pointer)
        }
        throw CLIError(message: "failed to exec \(executable): \(String(cString: strerror(execErrno)))")
    }

    /// Provider CLIs inherit this process environment after `execve`; keep
    /// ordinary shell/provider settings but strip cmux's socket credentials,
    /// routing identifiers, and debug control variables.
    private static func scrubbedSubrouterEnvironment() -> [String: String] {
        let allowedPrefixes = [
            "PATH", "HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD",
            "TMPDIR", "TERM", "LANG", "LC_", "SUBROUTER_", "CODEX_",
            "CLAUDE_", "ANTHROPIC_", "OPENAI_", "XDG_",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy"
        ]
        return ProcessInfo.processInfo.environment.filter { key, _ in
            allowedPrefixes.contains { prefix in
                prefix.hasSuffix("_") ? key.hasPrefix(prefix) : key == prefix
            }
        }
    }
}
