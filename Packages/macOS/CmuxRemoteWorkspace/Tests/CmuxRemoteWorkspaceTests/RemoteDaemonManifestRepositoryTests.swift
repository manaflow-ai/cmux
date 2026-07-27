import CmuxCore
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// Minimal loopback HTTP server: serves canned bodies by request path so the
/// repository's real `URLSession` paths (manifest fetch, binary download) run
/// against deterministic responses.
private final class FakeHTTPServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var responsesByPath: [String: (status: Int, body: Data)] = [:]

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "bind failed errno=\(errno)")
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        listenFD = fd
        port = Int(UInt16(bigEndian: actual.sin_port))
        precondition(listen(fd, 8) == 0)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                self?.serve(client: client)
            }
        }
    }

    func setResponse(path: String, status: Int = 200, body: Data) {
        lock.lock()
        responsesByPath[path] = (status, body)
        lock.unlock()
    }

    func close() {
        Darwin.close(listenFD)
    }

    private func serve(client: Int32) {
        var request = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = Darwin.read(client, &scratch, scratch.count)
            guard count > 0 else { break }
            request.append(scratch, count: count)
        }
        let head = String(decoding: request, as: UTF8.self)
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock()
        let response = responsesByPath[path] ?? (404, Data())
        lock.unlock()
        let header = "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(response.body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard n > 0 else { break }
                sent += n
            }
        }
        Darwin.close(client)
    }
}

@Suite("RemoteDaemonManifestRepository")
struct RemoteDaemonManifestRepositoryTests {
    private func makeRepository(home: URL) -> RemoteDaemonManifestRepository {
        RemoteDaemonManifestRepository(homeDirectory: home)
    }

    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-manifest-repo-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeEntry(port: Int, assetPath: String, sha256: String) -> WorkspaceRemoteDaemonManifest.Entry {
        let json = """
        {
          "goOS": "linux",
          "goArch": "amd64",
          "assetName": "cmuxd-remote-linux-amd64",
          "downloadURL": "http://127.0.0.1:\(port)\(assetPath)",
          "sha256": "\(sha256)"
        }
        """
        return try! JSONDecoder().decode(WorkspaceRemoteDaemonManifest.Entry.self, from: Data(json.utf8))
    }

    private func makeManifestJSON(port: Int, assetPath: String, sha256: String, appVersion: String = "0.99.0") -> String {
        """
        {
          "schemaVersion": 1,
          "appVersion": "\(appVersion)",
          "releaseTag": "v\(appVersion)",
          "releaseURL": "http://127.0.0.1:\(port)",
          "checksumsAssetName": "cmuxd-remote-checksums.txt",
          "checksumsURL": "http://127.0.0.1:\(port)/cmuxd-remote-checksums.txt",
          "entries": [
            {
              "goOS": "linux",
              "goArch": "amd64",
              "assetName": "cmuxd-remote-linux-amd64",
              "downloadURL": "http://127.0.0.1:\(port)\(assetPath)",
              "sha256": "\(sha256)"
            }
          ]
        }
        """
    }

    @Test("the cache path is versioned by platform under the cmux state directory")
    func cachePathShape() throws {
        let home = try temporaryHome()
        let url = try makeRepository(home: home).cachedBinaryURL(version: "0.62.0", goOS: "linux", goArch: "arm64")
        #expect(url.path == home.path + "/.local/state/cmux/remote-daemons/0.62.0/linux-arm64/cmuxd-remote")
        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".local/state/cmux/remote-daemons").path,
            isDirectory: &isDirectory
        )
        #expect(rootExists && isDirectory.boolValue, "cache root is created eagerly")
    }

    @Test("fetchManifest decodes a live manifest and returns nil on a non-2xx status")
    func fetchManifestStatuses() throws {
        let server = FakeHTTPServer()
        defer { server.close() }
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        let manifestJSON = makeManifestJSON(port: server.port, assetPath: "/bin", sha256: "abc123")

        server.setResponse(path: "/cmuxd-remote-manifest.json", body: Data(manifestJSON.utf8))
        let manifest = repository.fetchManifest(releaseURL: "http://127.0.0.1:\(server.port)", version: "0.99.0")
        #expect(manifest?.releaseTag == "v0.99.0")
        #expect(manifest?.entry(goOS: "linux", goArch: "amd64")?.assetName == "cmuxd-remote-linux-amd64")

        server.setResponse(path: "/cmuxd-remote-manifest.json", status: 500, body: Data())
        #expect(repository.fetchManifest(releaseURL: "http://127.0.0.1:\(server.port)", version: "0.99.0") == nil)
    }

    @Test("downloadBinary verifies the checksum and installs the binary executable at the cache path")
    func downloadHappyPath() throws {
        let server = FakeHTTPServer()
        defer { server.close() }
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        let binary = Data("#!/bin/sh\necho fake daemon\n".utf8)
        server.setResponse(path: "/cmuxd-remote-linux-amd64", body: binary)
        let entry = makeEntry(port: server.port, assetPath: "/cmuxd-remote-linux-amd64", sha256: sha256Hex(binary))

        let download = try repository.downloadBinary(entry: entry, version: "0.99.0")
        #expect(!download.usedLiveManifestChecksumFallback)
        #expect(download.binaryURL == (try repository.cachedBinaryURL(version: "0.99.0", goOS: "linux", goArch: "amd64")))
        #expect(try Data(contentsOf: download.binaryURL) == binary)
        #expect(FileManager.default.isExecutableFile(atPath: download.binaryURL.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: download.binaryURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test("a checksum mismatch with no live-manifest rescue throws the pinned code-28 error")
    func checksumMismatchThrows() throws {
        let server = FakeHTTPServer()
        defer { server.close() }
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        server.setResponse(path: "/cmuxd-remote-linux-amd64", body: Data("real bytes".utf8))
        let entry = makeEntry(port: server.port, assetPath: "/cmuxd-remote-linux-amd64", sha256: String(repeating: "0", count: 64))

        do {
            _ = try repository.downloadBinary(entry: entry, version: "0.99.0")
            Issue.record("expected checksum mismatch")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == 28)
            #expect(nsError.localizedDescription == "remote daemon checksum mismatch for cmuxd-remote-linux-amd64")
        }
        let cacheURL = try repository.cachedBinaryURL(version: "0.99.0", goOS: "linux", goArch: "amd64")
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test("a stale embedded checksum is rescued by the live release manifest and reported in the result")
    func checksumLiveManifestFallback() throws {
        let server = FakeHTTPServer()
        defer { server.close() }
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        let binary = Data("nightly-overwritten bytes".utf8)
        server.setResponse(path: "/cmuxd-remote-linux-amd64", body: binary)
        server.setResponse(
            path: "/cmuxd-remote-manifest.json",
            body: Data(makeManifestJSON(port: server.port, assetPath: "/cmuxd-remote-linux-amd64", sha256: sha256Hex(binary)).utf8)
        )
        let staleEntry = makeEntry(port: server.port, assetPath: "/cmuxd-remote-linux-amd64", sha256: String(repeating: "f", count: 64))

        let download = try repository.downloadBinary(
            entry: staleEntry,
            version: "0.99.0",
            releaseURL: "http://127.0.0.1:\(server.port)"
        )
        #expect(download.usedLiveManifestChecksumFallback)
        #expect(try Data(contentsOf: download.binaryURL) == binary)
    }

    @Test("an HTTP error status surfaces as the pinned code-26 error")
    func downloadHTTPErrorThrows() throws {
        let server = FakeHTTPServer()
        defer { server.close() }
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        server.setResponse(path: "/cmuxd-remote-linux-amd64", status: 503, body: Data())
        let entry = makeEntry(port: server.port, assetPath: "/cmuxd-remote-linux-amd64", sha256: String(repeating: "0", count: 64))

        do {
            _ = try repository.downloadBinary(entry: entry, version: "0.99.0")
            Issue.record("expected HTTP failure")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == 26)
            #expect(nsError.localizedDescription == "remote daemon download failed with HTTP 503")
        }
    }

    @Test("an invalid download URL surfaces as the pinned code-25 error")
    func invalidDownloadURLThrows() throws {
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        let entry = try JSONDecoder().decode(
            WorkspaceRemoteDaemonManifest.Entry.self,
            from: Data("""
            {"goOS": "linux", "goArch": "amd64", "assetName": "x", "downloadURL": "", "sha256": "00"}
            """.utf8)
        )
        do {
            _ = try repository.downloadBinary(entry: entry, version: "0.99.0")
            Issue.record("expected invalid-URL failure")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon")
            #expect(nsError.code == 25)
        }
    }

    @Test("validatedCachedBinary returns a matching executable cache hit and clears a stale one")
    func validatedCachedBinary() throws {
        let home = try temporaryHome()
        let repository = makeRepository(home: home)
        let binary = Data("cached daemon".utf8)
        let entry = makeEntry(port: 1, assetPath: "/unused", sha256: sha256Hex(binary))
        let cacheURL = try repository.cachedBinaryURL(version: "0.99.0", goOS: "linux", goArch: "amd64")

        // Missing: nil.
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == nil)

        // Present + matching + executable: hit.
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary.write(to: cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheURL.path)
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == cacheURL)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path), "a valid hit is not deleted")

        // Present + stale bytes: removed, nil.
        try Data("tampered".utf8).write(to: cacheURL)
        #expect(try repository.validatedCachedBinary(entry: entry, version: "0.99.0") == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    }
}
