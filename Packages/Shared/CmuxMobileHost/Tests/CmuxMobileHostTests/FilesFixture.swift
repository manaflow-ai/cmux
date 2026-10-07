import CmuxMobileLink
import CmuxMobileHost
import CmuxMobileWire
import CryptoKit
import Foundation

/// A throwaway home with a workspace directory, an inbox and a secret
/// outside every root, plus the files service configured on it.
struct FilesFixture {
    let home: URL
    let workspace: URL
    let secret: URL
    let configuration: MobileFilesConfiguration
    let files: MobileFiles

    init(maxUploadBytes: UInt64 = 1 << 30, chunkBytes: Int = 64 * 1024, workspaceWritable: Bool = true,
         extraRoots: [MobileFileRoot] = [], stagingQuotaBytes: UInt64 = 2 << 30, maxChannelsPerDevice: Int = 4) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("c4-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        workspace = home.appendingPathComponent("src/proj", isDirectory: true)
        secret = home.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("top secret".utf8).write(to: secret)
        configuration = MobileFilesConfiguration(homeDirectory: home, maxUploadBytes: maxUploadBytes, chunkBytes: chunkBytes,
                                                 stagingQuotaBytes: stagingQuotaBytes, freeSpaceMarginBytes: 0,
                                                 maxChannelsPerDevice: maxChannelsPerDevice)
        let root = MobileFileRoot(id: "ws_a1", name: "proj", url: workspace, writable: workspaceWritable)
        files = MobileFiles(configuration: configuration, roots: StaticFileRoots([root] + extraRoots))
    }

    var policy: MobileFilePolicy {
        MobileFilePolicy(configuration: configuration, roots: [MobileFileRoot(id: "ws_a1", name: "proj", url: workspace, writable: true)])
    }

    func remove() {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    static func uploadParams(_ data: Data, name: String = "photo.jpg", sha: String? = nil,
                             dest: FilesUploadDestination = FilesUploadDestination(kind: .terminal, terminal: "term_x1"))
        -> [String: JSONValue] {
        let params = FilesUploadParams(name: name, size: UInt64(data.count), mime: "image/jpeg",
                                       sha256: sha ?? sha256(data), dest: dest)
        return (try? JSONValue(encoding: params))?.objectValue ?? [:]
    }
}
