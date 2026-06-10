import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Remote daemon status and manifest
extension CMUXCLI {
    private struct RemoteDaemonManifest: Decodable {
        struct Entry: Decodable {
            let goOS: String
            let goArch: String
            let assetName: String
            let downloadURL: String
            let sha256: String
        }

        let schemaVersion: Int
        let appVersion: String
        let releaseTag: String
        let releaseURL: String
        let checksumsAssetName: String
        let checksumsURL: String
        let entries: [Entry]

        func entry(goOS: String, goArch: String) -> Entry? {
            entries.first { $0.goOS == goOS && $0.goArch == goArch }
        }
    }

    func generateRemoteRelayPort() -> Int {
        // Random port in the ephemeral range (49152-65535)
        Int.random(in: 49152...65535)
    }

    func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CLIError(message: "failed to generate SSH relay credential")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func runRemoteDaemonStatus(commandArgs: [String], jsonOutput: Bool) throws {
        let requestedOS = optionValue(commandArgs, name: "--os")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedArch = optionValue(commandArgs, name: "--arch")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = resolvedVersionInfo()
        let manifest = remoteDaemonManifest()
        let platform = defaultRemoteDaemonPlatform(requestedOS: requestedOS, requestedArch: requestedArch)
        let cacheURL = remoteDaemonCacheURL(version: manifest?.appVersion ?? remoteDaemonVersionString(from: info), goOS: platform.goOS, goArch: platform.goArch)
        let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
        let cacheSHA = cacheExists ? try? sha256Hex(forFile: cacheURL) : nil
        let entry = manifest?.entry(goOS: platform.goOS, goArch: platform.goArch)
        let cacheVerified = (entry != nil && cacheSHA?.lowercased() == entry?.sha256.lowercased())
        let releaseTag = manifest?.releaseTag ?? "unknown"
        let assetName = entry?.assetName ?? "unknown"
        let downloadURL = entry?.downloadURL ?? "unknown"
        let checksumsAssetName = manifest?.checksumsAssetName ?? "unknown"
        let checksumsURL = manifest?.checksumsURL ?? "unknown"
        let downloadCommand = "gh release download \(releaseTag) --repo manaflow-ai/cmux --pattern \(assetName)"
        let downloadChecksumsCommand = "gh release download \(releaseTag) --repo manaflow-ai/cmux --pattern \(checksumsAssetName)"
        let checksumVerifyCommand = "shasum -a 256 -c \(checksumsAssetName) --ignore-missing"
        let signerWorkflow = releaseTag == "nightly"
            ? "manaflow-ai/cmux/.github/workflows/nightly.yml"
            : "manaflow-ai/cmux/.github/workflows/release.yml"
        let verifyCommand = "gh attestation verify ./\(assetName) --repo manaflow-ai/cmux --signer-workflow \(signerWorkflow)"

        let payload: [String: Any] = [
            "app_version": remoteDaemonVersionString(from: info),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "commit": info["CMUXCommit"] ?? NSNull(),
            "manifest_present": manifest != nil,
            "release_tag": releaseTag,
            "release_url": manifest?.releaseURL ?? NSNull(),
            "target_goos": platform.goOS,
            "target_goarch": platform.goArch,
            "asset_name": assetName,
            "download_url": downloadURL,
            "checksums_asset_name": checksumsAssetName,
            "checksums_url": checksumsURL,
            "expected_sha256": entry?.sha256 ?? NSNull(),
            "cache_path": cacheURL.path,
            "cache_exists": cacheExists,
            "cache_sha256": cacheSHA ?? NSNull(),
            "cache_verified": cacheVerified,
            "dev_local_build_fallback": ProcessInfo.processInfo.environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1",
            "download_command": downloadCommand,
            "download_checksums_command": downloadChecksumsCommand,
            "checksum_verify_command": checksumVerifyCommand,
            "attestation_verify_command": verifyCommand,
        ]

        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("app version: \(payload["app_version"] as? String ?? "unknown")")
        if let build = payload["build"] as? String {
            print("build: \(build)")
        }
        if let commit = payload["commit"] as? String {
            print("commit: \(commit)")
        }
        print("manifest: \(manifest != nil ? "present" : "missing")")
        print("platform: \(platform.goOS)/\(platform.goArch)")
        print("release: \(releaseTag)")
        print("asset: \(assetName)")
        print("download url: \(downloadURL)")
        print("checksums asset: \(checksumsAssetName)")
        print("checksums: \(checksumsURL)")
        if let expectedSHA = entry?.sha256 {
            print("expected sha256: \(expectedSHA)")
        }
        print("cache: \(cacheURL.path)")
        print("cache exists: \(cacheExists ? "yes" : "no")")
        if let cacheSHA {
            print("cache sha256: \(cacheSHA)")
        }
        print("cache verified: \(cacheVerified ? "yes" : "no")")
        print("download command: \(downloadCommand)")
        print("download checksums: \(downloadChecksumsCommand)")
        print("verify checksum: \(checksumVerifyCommand)")
        print("attestation verify: \(verifyCommand)")
        if manifest == nil {
            print("note: this build has no embedded remote daemon manifest. Set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 only for dev builds.")
        }
    }

    private func defaultRemoteDaemonPlatform(requestedOS: String?, requestedArch: String?) -> (goOS: String, goArch: String) {
        let normalizedOS = requestedOS?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedArch = requestedArch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let goOS = (normalizedOS?.isEmpty == false ? normalizedOS! : hostGoOS())
        let goArch = (normalizedArch?.isEmpty == false ? normalizedArch! : hostGoArch())
        return (goOS, goArch)
    }

    private func hostGoOS() -> String {
#if os(macOS)
        return "darwin"
#elseif os(Linux)
        return "linux"
#else
        return "unknown"
#endif
    }

    private func hostGoArch() -> String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "amd64"
#else
        return "unknown"
#endif
    }

    private func remoteDaemonManifest() -> RemoteDaemonManifest? {
        for plistURL in candidateInfoPlistURLs() {
            guard let raw = NSDictionary(contentsOf: plistURL) as? [String: Any],
                  let rawManifest = raw["CMUXRemoteDaemonManifestJSON"] as? String,
                  let data = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let manifest = try? JSONDecoder().decode(RemoteDaemonManifest.self, from: data) else {
                continue
            }
            return manifest
        }
        return nil
    }

    private func remoteDaemonVersionString(from info: [String: String]) -> String {
        info["CFBundleShortVersionString"] ?? "dev"
    }

    private func remoteDaemonCacheURL(version: String, goOS: String, goArch: String) -> URL {
        // Cache under the non-TCC cmux state directory rather than Application
        // Support: the separately-signed CLI downloads these on `cmux ssh`, and a
        // cross-identity reach into the app's Application Support data triggers the
        // macOS Sequoia "access data from other apps" prompt
        // (https://github.com/manaflow-ai/cmux/issues/5146). The app's
        // Workspace.remoteDaemonCachedBinaryURL resolves the same path. The CLI is
        // a composition root, so it names the concrete `FileManager.default` here.
        return CmuxStateDirectory.url(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("remote-daemons", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    private func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

}
