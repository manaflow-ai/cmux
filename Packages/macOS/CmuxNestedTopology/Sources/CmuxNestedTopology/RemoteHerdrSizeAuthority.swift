public import Foundation

/// Single size-claim writer shared with plugin ``cmux_herdr_mirror.size_authority_*``.
///
/// File format matches the plugin: one line, the pane id (or ``native`` sentinel)
/// allowed to call Herdr ``pane.resize`` / feed-forward client-size claim.
/// Dual writers thrash SIGWINCH; native attachment must own this file while live.
public enum RemoteHerdrSizeAuthority {
    /// Token written while the native mirror owns sizing (no plugin pane matches).
    public static let nativeToken = "native"
    public static let envKey = "CMUX_HERDR_SIZE_AUTHORITY"

    /// Paths both plugin and native read/write for one fingerprint.
    public static func paths(
        fingerprint: String,
        directories: [URL]
    ) -> [URL] {
        directories.map { $0.appendingPathComponent("size-authority-\(fingerprint)") }
    }

    public static func envAuthority(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let raw = (environment[envKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

/// File-backed size-authority store. Inject directories in tests.
public struct RemoteHerdrSizeAuthorityStore: Sendable {
    public var directories: [URL]
    public var environment: [String: String]

    public init(
        directories: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directories = directories
        self.environment = environment
    }

    /// Prefer env override, else first readable size-authority file.
    public func read(fingerprint: String) -> String? {
        if let env = RemoteHerdrSizeAuthority.envAuthority(environment: environment) {
            return env
        }
        for path in RemoteHerdrSizeAuthority.paths(
            fingerprint: fingerprint,
            directories: directories
        ) {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                continue
            }
            let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return nil
    }

    /// True when *paneID* may claim Herdr client size for this fingerprint.
    public func mayClaim(paneID: String, fingerprint: String) -> Bool {
        let authority = read(fingerprint: fingerprint)
        if let authority {
            return authority == paneID
        }
        // No election yet: allow (single-viewer / first-attach fallback).
        return true
    }

    /// Persist which pane (or ``native``) may claim size. Empty *paneID* clears.
    @discardableResult
    public func write(paneID: String?, fingerprint: String) -> [URL] {
        let paths = RemoteHerdrSizeAuthority.paths(
            fingerprint: fingerprint,
            directories: directories
        )
        guard let paneID, !paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            for path in paths {
                try? FileManager.default.removeItem(at: path)
            }
            return []
        }
        let body = paneID.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        var written: [URL] = []
        for path in paths {
            do {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = path.appendingPathExtension("tmp")
                try body.write(to: temporary, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: path)
                try FileManager.default.moveItem(at: temporary, to: path)
                written.append(path)
            } catch {
                continue
            }
        }
        return written
    }

    /// Claim size authority for the native mirror (plugin attach-pane must no-op).
    @discardableResult
    public func claimNative(fingerprint: String) -> [URL] {
        write(paneID: RemoteHerdrSizeAuthority.nativeToken, fingerprint: fingerprint)
    }

    /// Drop size-authority files for *fingerprint*.
    public func clear(fingerprint: String) {
        write(paneID: nil, fingerprint: fingerprint)
    }
}
