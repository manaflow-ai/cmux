import Foundation

// The bundled subrouter binary: the app ships Resources/bin/subrouter.gz
// (built from the pinned submodule by scripts/build-subrouter.sh); the CLI
// extracts it once per bundled version into Application Support and routes
// `cmux sr …` / unknown `cmux subrouter …` verbs to it. A user-installed
// sr on PATH always wins, so bundling only changes machines with no sr.
extension CMUXCLI {
    /// The directory extracted subrouter binaries live in.
    static var bundledSubrouterInstallDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux/bin", isDirectory: true)
    }

    /// The compressed binary inside the app bundle, located relative to the
    /// bundled CLI (`<app>/Contents/Resources/bin/cmux`), or `nil` when the
    /// CLI runs outside an app bundle that ships one.
    static func bundledSubrouterArchivePath() -> String? {
        var candidates: [String] = []
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
                let staging = installDir.appendingPathComponent(".subrouter.extracting")
                try? fileManager.removeItem(at: staging)
                // gunzip -c preserves the embedded ad-hoc code signature.
                let gunzip = Process()
                gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                gunzip.arguments = ["-c", archivePath]
                fileManager.createFile(atPath: staging.path, contents: nil)
                gunzip.standardOutput = try FileHandle(forWritingTo: staging)
                try gunzip.run()
                gunzip.waitUntilExit()
                guard gunzip.terminationStatus == 0 else {
                    try? fileManager.removeItem(at: staging)
                    return nil
                }
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
                _ = try? fileManager.removeItem(at: binaryURL)
                try fileManager.moveItem(at: staging, to: binaryURL)
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
            return personaURL.path
        }
        return binaryURL.path
    }

    /// Installs the bundled binary into `~/bin` as `subrouter` + `sr`
    /// symlinks (the layout the official installer produces, and the one
    /// the app's account switcher and plain terminals resolve). Returns the
    /// `sr` path, or `nil` when nothing is bundled.
    func installBundledSubrouterIntoHomeBin() -> String? {
        guard let extracted = Self.extractedSubrouterBinary(persona: "subrouter") else {
            return nil
        }
        let fileManager = FileManager.default
        let homeBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin", isDirectory: true)
        do {
            try fileManager.createDirectory(at: homeBin, withIntermediateDirectories: true)
            for name in ["subrouter", "sr"] {
                let link = homeBin.appendingPathComponent(name)
                if fileManager.fileExists(atPath: link.path) { continue }
                try fileManager.createSymbolicLink(
                    atPath: link.path,
                    withDestinationPath: extracted
                )
            }
        } catch {
            return nil
        }
        let sr = homeBin.appendingPathComponent("sr").path
        return fileManager.isExecutableFile(atPath: sr) ? sr : nil
    }

    /// Replaces this process with the subrouter binary running `arguments`
    /// under the given persona. Prefers a user-installed sr from PATH, then
    /// the bundled binary. Only returns on failure.
    func execSubrouter(persona: String, arguments: [String]) throws -> Never {
        let executable = resolveSubrouterBinary()
            ?? Self.extractedSubrouterBinary(persona: persona)
        guard let executable else {
            throw CLIError(message: """
                subrouter is not installed and this cmux build does not bundle it.
                Install it with: curl -fsSL https://github.com/manaflow-ai/subrouter/releases/latest/download/install.sh | sh
                """)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(persona)]
        argv.append(contentsOf: arguments.map { strdup($0) })
        argv.append(nil)
        execv(executable, argv)
        throw CLIError(message: "failed to exec \(executable): \(String(cString: strerror(errno)))")
    }
}
