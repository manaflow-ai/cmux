import Foundation

/// Whole-tree filesystem scans for template validation: symlink rejection
/// and the secret-material sweep. Split from `OrchestrationValidator.swift`
/// to keep both files under the repo's Swift file-length threshold.
extension OrchestrationValidator {
    /// Templates must not contain symlinks: `fileExists` and reads resolve
    /// them, so a symlinked prompt or script could reach outside the
    /// template root (e.g. `prompts/task.md -> ~/.ssh/id_rsa`) and leak the
    /// target's contents into rendered prompts at run time.
    func validateNoSymlinks(
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        for relativePath in symlinkPaths(under: templateDirectory) {
            findings.append(.init(
                severity: .error,
                code: "symlink",
                message: "'\(relativePath)' is a symbolic link; templates must contain regular files only",
                path: relativePath
            ))
        }
    }

    private func symlinkPaths(under root: String, prefix: String = "", depth: Int = 0) -> [String] {
        guard depth < 6, let entries = try? fileSystem.contentsOfDirectory(atPath: root) else { return [] }
        var results: [String] = []
        for entry in entries.sorted() {
            if entry == ".git" { continue }
            let absolute = join(root, entry)
            let relative = prefix.isEmpty ? entry : "\(prefix)/\(entry)"
            if fileSystem.isSymbolicLink(atPath: absolute) {
                results.append(relative)
            } else if fileSystem.directoryExists(atPath: absolute) {
                results.append(contentsOf: symlinkPaths(under: absolute, prefix: relative, depth: depth + 1))
            }
        }
        return results
    }

    /// High-confidence secret-material patterns. Templates are shared
    /// artifacts; credentials must stay on the user's machine.
    private static let secretPatterns: [String] = [
        "ghp_",
        "github_pat_",
        "sk-ant-",
        "xoxb-",
        "xoxp-",
        "AKIA",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
    ]

    func scanForSecrets(
        _ manifest: OrchestrationManifest,
        in templateDirectory: String,
        into findings: inout [OrchestrationValidationFinding]
    ) {
        for relativePath in textFiles(under: templateDirectory) {
            guard let data = try? fileSystem.readData(atPath: join(templateDirectory, relativePath)),
                  data.count < 1_048_576,
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for pattern in Self.secretPatterns where text.contains(pattern) {
                findings.append(.init(
                    severity: .error,
                    code: "secret-material",
                    message: "File '\(relativePath)' contains what looks like secret material ('\(pattern)…'); templates must never contain secrets",
                    path: relativePath
                ))
            }
        }
    }

    /// Walks the template (skipping `.git`) and returns relative file paths.
    private func textFiles(under root: String, prefix: String = "", depth: Int = 0) -> [String] {
        guard depth < 6, let entries = try? fileSystem.contentsOfDirectory(atPath: root) else { return [] }
        var results: [String] = []
        for entry in entries.sorted() {
            if entry == ".git" { continue }
            let absolute = join(root, entry)
            let relative = prefix.isEmpty ? entry : "\(prefix)/\(entry)"
            if fileSystem.directoryExists(atPath: absolute) {
                results.append(contentsOf: textFiles(under: absolute, prefix: relative, depth: depth + 1))
            } else {
                results.append(relative)
            }
        }
        return results
    }
}
