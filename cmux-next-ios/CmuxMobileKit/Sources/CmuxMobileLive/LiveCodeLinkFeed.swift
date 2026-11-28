// Swift live code on a device (cmuxterm-hq docs/design/ios-dev-channels.md, step 4): the Mac's
// patches arrive over the link, not through a folder the phone could read. The Mac's host serves
// them on the `live-code` service (`cmux-mobile-host` `live_code.rs`); this writes each one into the
// app's own live folder, where the live code engine (Packages/Shared/CmuxLiveCode, LiveCodeRedraw)
// checks its signature and loads it, and sends the folder's new log lines back, so
// scripts/live-code/ios-device.sh reads the phone's answer on the Mac.
//
// Only a DEBUG build has it, and it opens the channel only in cmux Dev or a tagged dev build
// (`dev.cmux.mobile.*`) launched with CMUX_LIVE_CODE_LINK=1: a Release binary holds none of it.
#if os(iOS) && DEBUG
import CmuxMobileTransport
import CryptoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "live-code")

public enum LiveCodeLinkFeed {
    public static let service = "live-code"
    /// The largest patch taken (hostd sends at most this).
    public static let maxPatchBytes = 64 << 20
    /// How often the log is read for new lines while the channel is open.
    static let logPoll: Duration = .milliseconds(100)

    /// cmux Dev or a tagged dev build, launched with CMUX_LIVE_CODE_LINK=1. The engine's gate
    /// (CmuxLiveCode `LiveCodeDeviceGate`) reads the same two.
    static func enabled(bundleID: String?, environment: [String: String]) -> Bool {
        let prefix = "dev.cmux.mobile."
        guard let bundleID, bundleID.hasPrefix(prefix), bundleID.count > prefix.count else { return false }
        return environment["CMUX_LIVE_CODE_LINK"] == "1"
    }

    /// The engine's folder (CmuxLiveCode `LiveCodeDeviceGate.folder()`).
    static func folder() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-live-code/live", isDirectory: true)
    }

    /// One entry's header frame: `{"name","bytes","sha256"}`.
    struct Header: Decodable, Equatable {
        var name: String
        var bytes: Int
        var sha256: String
    }

    /// A header the phone takes: a patch or an undo request with a plain, visible name.
    static func header(_ frame: Data) -> Header? {
        guard let header = try? JSONDecoder().decode(Header.self, from: frame),
              !header.name.hasPrefix("."), !header.name.contains("/"), !header.name.contains("\0"),
              header.name.hasSuffix(".dylib") || header.name.hasSuffix(".rollback") || header.name.hasSuffix(".rollback-all"),
              header.bytes >= 0, header.bytes <= maxPatchBytes,
              header.name.hasSuffix(".dylib") || header.bytes == 0 else { return nil }
        return header
    }

    /// `body` when it is the one `header` announced (its size and SHA-256).
    static func verified(_ body: Data, _ header: Header) -> Bool {
        guard body.count == header.bytes else { return false }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return digest == header.sha256.lowercased()
    }

    /// Puts `body` in `folder` as `name` at once: written hidden, then renamed, so the engine never
    /// sees half a patch.
    static func place(_ body: Data, name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hidden = folder.appendingPathComponent(".\(name).part")
        try body.write(to: hidden, options: .atomic)
        let final = folder.appendingPathComponent(name)
        if rename(hidden.path, final.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: hidden)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "rename: \(String(cString: strerror(code)))"])
        }
    }

    /// The log's complete lines after `offset`, and the offset after the last one.
    static func lines(in data: Data, from offset: Int) -> (lines: [String], next: Int) {
        guard offset < data.count else { return ([], min(offset, data.count)) }
        let tail = data[offset...]
        guard let last = tail.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }
        let text = String(decoding: data[offset..<last], as: UTF8.self)
        return (text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init), last + 1)
    }

    /// Reads `link`'s `live-code` service until the channel or the link closes, when this build may.
    public static func read(on link: any MacLink, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard enabled(bundleID: Bundle.main.bundleIdentifier, environment: environment) else { return }
        await serve(on: link, folder: folder())
    }

    static func serve(on link: any MacLink, folder: URL) async {
        let channel: any LinkChannel
        do {
            channel = try await link.openChannel(service: service, args: [:])
        } catch {
            log.info("live-code channel: \(String(describing: error), privacy: .public)")
            return
        }
        let logURL = folder.appendingPathComponent("live-code.log")
        // Only lines written from now on go to the Mac: older ones belong to an earlier run.
        let start = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
        // task-owner: this channel; cancelled when the Mac's side ends.
        let forward = Task.detached(priority: .utility) {
            var offset = start
            while !Task.isCancelled {
                if let data = FileManager.default.contents(atPath: logURL.path) {
                    if data.count < offset { offset = 0 }
                    let (lines, next) = Self.lines(in: data, from: offset)
                    offset = next
                    for line in lines { try? await channel.send(Data(line.utf8)) }
                }
                try? await Task.sleep(for: Self.logPoll)
            }
        }
        defer { forward.cancel() }
        do {
            while let frame = try await channel.receive() {
                guard let header = header(frame) else {
                    await channel.close(code: "invalid", reason: "not a live code header")
                    return
                }
                var body = Data()
                body.reserveCapacity(header.bytes)
                while body.count < header.bytes, let chunk = try await channel.receive() {
                    body.append(chunk)
                }
                guard body.count == header.bytes else {
                    // A frame past the announced size: the stream is out of step.
                    await channel.close(code: "invalid", reason: "a patch longer than announced")
                    return
                }
                guard verified(body, header) else {
                    try? await channel.send(Data("live code: \(header.name) refused: its bytes do not match the Mac's".utf8))
                    continue
                }
                do {
                    try place(body, name: header.name, in: folder)
                } catch {
                    try? await channel.send(Data("live code: \(header.name) refused: \(error.localizedDescription)".utf8))
                }
            }
        } catch {
            log.info("live-code channel: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
