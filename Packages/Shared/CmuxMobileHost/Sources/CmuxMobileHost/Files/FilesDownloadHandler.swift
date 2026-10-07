import CmuxMobileLink
import CmuxLink
import CmuxMobileWire
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Serves `files.download` (c4-files.md sections 3 and 4): resolves the path
/// in scope, opens it without following a final symlink, checks it is the
/// regular file the policy resolved, answers size, mime and sha256, then
/// streams chunks from the requested offset; the last carries `fin`. The
/// link's credit throttles the loop, so a stalled phone holds at most one
/// channel budget in flight; after `fin` the handler waits a bounded grace
/// for the phone to take the tail, then closes.
public struct FilesDownloadHandler: MobileChannelHandler {
    static let window: UInt32 = 4 * 1024 * 1024

    let configuration: MobileFilesConfiguration
    let roots: any MobileFileRootsProvider
    let limiter: FilesChannelLimiter
    let clock: LinkClock

    init(configuration: MobileFilesConfiguration, roots: any MobileFileRootsProvider, limiter: FilesChannelLimiter,
         clock: LinkClock) {
        self.configuration = configuration
        self.roots = roots
        self.limiter = limiter
        self.clock = clock
    }

    public func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
                      gate: MobileSessionGate) async {
        guard await gate.isOpen else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        guard let params = try? JSONValue.object(open.params).decode(as: FilesDownloadParams.self) else {
            await channel.refuse(code: "validation.invalid", message: "bad files.download params")
            return
        }
        guard await limiter.acquire(principal.install) else {
            await channel.refuse(code: "validation.invalid", message: "too many transfers at once", retryable: true)
            return
        }
        await serveAcquired(channel, params: params, principal: principal, gate: gate)
        await limiter.release(principal.install)
    }

    private func serveAcquired(_ channel: MobileChannel, params: FilesDownloadParams, principal: MobileDevicePrincipal,
                               gate: MobileSessionGate) async {
        let policy = MobileFilePolicy(configuration: configuration, roots: await roots.roots(for: principal))
        let fd: Int32
        let size: UInt64
        let path: String
        do throws(MobileDaemonError) {
            let resolved = try policy.resolveExisting(params.path)
            path = resolved.path
            (fd, size) = try Self.openRegularFile(resolved.path)
        } catch {
            await channel.refuse(code: error.code, message: error.message, retryable: error.retryable)
            return
        }
        let streamed = await withFile(fd) {
            guard size <= configuration.maxDownloadBytes else {
                await channel.refuse(code: "files.too_large", message: "file", details: .object(["reason": .string("file")]))
                return false
            }
            guard let digest = await BlockingIO.run({ FileDigest(descriptor: fd).sha256(length: size) }) else {
                await channel.refuse(code: "owner.unreachable", message: "the file could not be read", retryable: true)
                return false
            }
            let opened = FilesDownloadOpenedParams(size: size, mime: FileMime(name: path).value, sha256: digest)
            guard let openedParams = try? JSONValue(encoding: opened).objectValue,
                  (try? await channel.send(frame: .channelOpened(ChannelOpenedFrame(
                      channel: channel.id, window: Self.window, params: openedParams, resumed: (params.offset ?? 0) > 0)))) != nil else {
                return false
            }
            return await stream(channel, fd: fd, size: size, from: min(params.offset ?? 0, size), gate: gate)
        }
        guard streamed else { return }
        // The descriptor is closed; give the phone a bounded grace to take the tail.
        await OnceSignal.bounded(configuration.finishGrace, clock: clock) {
            await channel.finish()
        }
        await channel.abort()
    }

    /// Runs `body` and closes `fd` right after it, before any wait on the peer.
    private func withFile(_ fd: Int32, _ body: () async -> Bool) async -> Bool {
        let result = await body()
        close(fd)
        return result
    }

    /// Returns false when the channel ended early.
    private func stream(_ channel: MobileChannel, fd: Int32, size: UInt64, from start: UInt64,
                        gate: MobileSessionGate) async -> Bool {
        var offset = start
        var buffer = [UInt8](repeating: 0, count: configuration.chunkBytes)
        repeat {
            guard await gate.isOpen else {
                await channel.abort()
                return false
            }
            let want = Int(min(UInt64(configuration.chunkBytes), size - offset))
            let got = want == 0 ? 0 : buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            guard got >= 0, got == want else {
                await channel.close(code: "owner.unreachable", message: "the file changed while reading")
                return false
            }
            let last = offset + UInt64(got) == size
            let chunk = FileChunk(offset: offset, data: Data(buffer[0..<got]))
            do {
                try await channel.send(binary: chunk.encoded, flags: last ? .fin : [])
            } catch {
                return false
            }
            offset += UInt64(got)
        } while offset < size
        return true
    }

    /// Opens with `O_NOFOLLOW` and checks the descriptor is a regular file
    /// with the device and inode the resolved path has (no final swap).
    static func openRegularFile(_ path: String) throws(MobileDaemonError) -> (Int32, UInt64) {
        var before = stat()
        guard lstat(path, &before) == 0 else { throw .filesNotFound() }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw .filesNotFound("the file could not be opened") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_dev == before.st_dev, info.st_ino == before.st_ino else {
            close(fd)
            throw MobileDaemonError(code: "files.not_found", message: "not a regular file")
        }
        return (fd, UInt64(info.st_size))
    }
}
