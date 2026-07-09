import Foundation

/// One web extension that can be loaded into the browser: either a Safari web
/// extension installed on this Mac (inside some app's `.appex`) or a directory
/// containing an unpacked WebExtension the user added manually.
struct BrowserWebExtensionCandidate: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case safariAppExtension
        case unpackedDirectory
    }

    /// Stable identity used for the enabled-set in settings: the appex plugin
    /// identifier for Safari extensions, or the directory path for unpacked ones.
    let id: String
    let kind: Kind
    let path: String
    let version: String?
    let displayName: String?
}

/// Discovers Safari web extensions registered with the system.
///
/// Uses `pluginkit -m -p com.apple.Safari.web-extension` — the same registry
/// Safari itself consults — so anything the user installed via an app bundle
/// (Bitwarden, 1Password, AdGuard, …) is found without configuration.
actor BrowserWebExtensionDiscoveryService {
    private static let pluginkitURL = URL(fileURLWithPath: "/usr/bin/pluginkit")

    func discoverInstalledSafariExtensions() async -> [BrowserWebExtensionCandidate] {
        let output: String
        do {
            output = try await runPluginkit()
        } catch {
            return []
        }
        return Self.parse(pluginkitOutput: output)
    }

    /// Parses `pluginkit -m -A -v` machine listing: one plug-in per line,
    /// tab-separated `identifier(version)`, UUID, timestamp, absolute path.
    static func parse(pluginkitOutput: String) -> [BrowserWebExtensionCandidate] {
        var seen = Set<String>()
        var candidates: [BrowserWebExtensionCandidate] = []
        for line in pluginkitOutput.split(separator: "\n") {
            let columns = line.split(separator: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = columns.first, columns.count >= 2 else { continue }
            guard let path = columns.last, path.hasSuffix(".appex") else { continue }

            // `identifier(version)` — a leading `+`/`-`/`?` marks election state.
            var identifierField = first
            while let head = identifierField.first, ["+", "-", "?", "!"].contains(String(head)) {
                identifierField = String(identifierField.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            var identifier = identifierField
            var version: String?
            if let open = identifierField.lastIndex(of: "("), identifierField.hasSuffix(")") {
                identifier = String(identifierField[..<open]).trimmingCharacters(in: .whitespaces)
                version = String(identifierField[identifierField.index(after: open)..<identifierField.index(before: identifierField.endIndex)])
            }
            guard !identifier.isEmpty, seen.insert(identifier).inserted else { continue }
            candidates.append(BrowserWebExtensionCandidate(
                id: identifier,
                kind: .safariAppExtension,
                path: path,
                version: version,
                displayName: Self.displayName(forAppexAt: path)
            ))
        }
        return candidates.sorted { $0.id < $1.id }
    }

    /// Prefers the containing app's name ("Bitwarden") over the appex's own
    /// bundle name, which is often a generic "safari".
    private static func displayName(forAppexAt path: String) -> String? {
        let appexURL = URL(fileURLWithPath: path)
        // …/SomeApp.app/Contents/PlugIns/foo.appex → SomeApp.app
        let containingApp = appexURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if containingApp.pathExtension == "app" {
            return containingApp.deletingPathExtension().lastPathComponent
        }
        guard let bundle = Bundle(url: appexURL) else { return nil }
        return (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
    }

    private func runPluginkit() async throws -> String {
        let process = Process()
        process.executableURL = Self.pluginkitURL
        process.arguments = ["-m", "-p", "com.apple.Safari.web-extension", "-A", "-v"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        var data = Data()
        // EOF on stdout is the completion signal; pluginkit's exit status is
        // uninteresting (an empty listing and a failure both mean "none found").
        for try await byte in stdout.fileHandleForReading.bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
