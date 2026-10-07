import CmuxMobileWire
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Serves `files.upload` (c4-files.md sections 3 and 4): validates params,
/// scope and caps, resumes from the staged partial, appends chunks only at
/// the partial's exact length, verifies sha256 on `files.upload.end`, then
/// moves the file into its destination without overwriting anything.
public struct FilesUploadHandler: MobileChannelHandler {
    static let window: UInt32 = 4 * 1024 * 1024
    /// Free disk is re-checked every this many received bytes.
    static let diskCheckBytes: UInt64 = 64 * 1024 * 1024

    let configuration: MobileFilesConfiguration
    let roots: any MobileFileRootsProvider
    let staging: UploadStaging
    let limiter: FilesChannelLimiter

    init(configuration: MobileFilesConfiguration, roots: any MobileFileRootsProvider, staging: UploadStaging,
         limiter: FilesChannelLimiter) {
        self.configuration = configuration
        self.roots = roots
        self.staging = staging
        self.limiter = limiter
    }

    public func serve(_ channel: MobileChannel, open: ChannelOpenFrame, principal: MobileDevicePrincipal,
                      gate: MobileSessionGate) async {
        guard await gate.isOpen else {
            await channel.refuse(code: "auth.revoked", message: "this device was revoked")
            return
        }
        guard let params = try? JSONValue.object(open.params).decode(as: FilesUploadParams.self),
              FileDigest.isValidHex(params.sha256), !params.name.isEmpty, params.name.utf8.count <= 255 else {
            await channel.refuse(code: "validation.invalid", message: "bad files.upload params")
            return
        }
        guard params.size <= configuration.maxUploadBytes else {
            await refuse(channel, .filesTooLarge("file"))
            return
        }
        guard await limiter.acquire(principal.install) else {
            await channel.refuse(code: "validation.invalid", message: "too many transfers at once", retryable: true)
            return
        }
        await serveClaimed(channel, params: params, principal: principal, gate: gate)
        await limiter.release(principal.install)
    }

    private func serveClaimed(_ channel: MobileChannel, params: FilesUploadParams, principal: MobileDevicePrincipal,
                              gate: MobileSessionGate) async {
        let claim: UploadStaging.Claim
        do throws(MobileDaemonError) {
            _ = try await destination(for: params, principal: principal)
            claim = try await staging.claim(install: principal.install, sha256: params.sha256, size: params.size) {
                await channel.abort()
            }
        } catch {
            await refuse(channel, error)
            return
        }
        if let placed = claim.placed {
            await answerPlaced(channel, params: params, claim: claim, path: placed)
        } else {
            await receive(channel, params: params, claim: claim, principal: principal, gate: gate)
        }
        await staging.release(claim)
    }

    /// The destination directory, resolved against the roots as they are now.
    private func destination(for params: FilesUploadParams, principal: MobileDevicePrincipal)
        async throws(MobileDaemonError) -> MobileFilePolicy.Resolved {
        let policy = MobileFilePolicy(configuration: configuration, roots: await roots.roots(for: principal))
        switch params.dest.kind {
        case .terminal, .composer:
            return try policy.ensureInbox()
        case .path:
            guard let path = params.dest.path else {
                throw MobileDaemonError(code: "files.dest_invalid", message: "dest.path is required")
            }
            return try policy.resolveWritableDirectory(path)
        }
    }

    private func receive(_ channel: MobileChannel, params: FilesUploadParams, claim: UploadStaging.Claim,
                         principal: MobileDevicePrincipal, gate: MobileSessionGate) async {
        let fd = Darwin.open(claim.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            await channel.refuse(code: "owner.unreachable", message: "the upload could not be staged", retryable: true)
            return
        }
        defer { close(fd) }
        var length = UInt64(max(0, lseek(fd, 0, SEEK_END)))
        if length > params.size {
            ftruncate(fd, 0)
            length = 0
        }
        guard await sendOpened(channel, claim: claim, offset: length) else { return }
        var nextDiskCheck = length + Self.diskCheckBytes
        while true {
            switch await channel.receive() {
            case .binary(let payload, _):
                guard await gate.isOpen else {
                    await channel.abort()
                    return
                }
                guard let chunk = try? FileChunk(decoding: payload), chunk.offset == length,
                      length + UInt64(chunk.data.count) <= params.size else {
                    await channel.close(code: "proto.bad_record", message: "chunk at \(length) expected")
                    return
                }
                if length >= nextDiskCheck {
                    guard await staging.hasRoom(for: params.size - length, path: claim.path) else {
                        await channel.close(code: "files.too_large", message: "disk")
                        return
                    }
                    nextDiskCheck = length + Self.diskCheckBytes
                }
                guard Self.write(chunk.data, to: fd, at: length) else {
                    await channel.close(code: "owner.unreachable", message: "write failed")
                    return
                }
                length += UInt64(chunk.data.count)
            case .json(let value):
                if case .message(let message)? = try? MobileJSON(value: value), let end = FilesUploadEnd(message) {
                    await finish(channel, params: params, end: end, claim: claim, fd: fd, length: length,
                                 principal: principal, gate: gate)
                    return
                }
                if case .channelClose? = try? MobileFrame(value: value) {
                    await channel.finish()
                    return
                }
                await channel.close(code: "proto.unknown_frame", message: "unexpected record on files.upload")
                return
            case .gap:
                await channel.close(code: "proto.bad_record", message: "bytes were lost; reopen to resume")
                return
            case .closed:
                // Cancelled or disconnected: the partial stays for resume.
                return
            }
        }
    }

    private func finish(_ channel: MobileChannel, params: FilesUploadParams, end: FilesUploadEnd,
                        claim: UploadStaging.Claim, fd: Int32, length: UInt64, principal: MobileDevicePrincipal,
                        gate: MobileSessionGate) async {
        guard length == params.size else {
            await channel.close(code: "validation.invalid", message: "the upload ended at \(length) of \(params.size)")
            return
        }
        guard await gate.isOpen else {
            await channel.abort()
            return
        }
        let digest = await BlockingIO.run {
            fsync(fd)
            return FileDigest(descriptor: fd).sha256(length: length)
        }
        guard let digest, digest == params.sha256, end.sha256 == params.sha256 else {
            unlink(claim.path)
            await channel.close(code: "files.digest_mismatch", message: "the bytes do not match sha256")
            return
        }
        // Roots may have changed since the open (a workspace closed); scope again.
        let destination: MobileFilePolicy.Resolved
        do throws(MobileDaemonError) {
            destination = try await self.destination(for: params, principal: principal)
        } catch {
            await channel.close(code: error.code, message: error.message)
            return
        }
        guard await gate.isOpen else {
            await channel.abort()
            return
        }
        let source = claim.path
        let name = MobileFilePolicy.sanitizedName(params.name)
        let placement = await BlockingIO.run { () -> Result<String, MobileDaemonError> in
            do throws(MobileDaemonError) {
                return .success(try MobilePlacement(source: source, directory: destination.path, name: name).place())
            } catch {
                return .failure(error)
            }
        }
        switch placement {
        case .success(let final):
            await staging.placed(claim, at: final)
            try? await channel.send(message: FilesUploadDone(upload: claim.uploadID, path: final, size: length).message)
            await channel.finish()
        case .failure(let error):
            await channel.close(code: error.code, message: error.message)
        }
    }

    /// A reopen of an upload this Mac already placed: report it complete and
    /// answer `files.upload.end` with the same path.
    private func answerPlaced(_ channel: MobileChannel, params: FilesUploadParams, claim: UploadStaging.Claim,
                              path: String) async {
        guard await sendOpened(channel, claim: claim, offset: params.size) else { return }
        while true {
            switch await channel.receive() {
            case .json(let value):
                guard case .message(let message)? = try? MobileJSON(value: value), FilesUploadEnd(message) != nil else {
                    await channel.finish()
                    return
                }
                try? await channel.send(message: FilesUploadDone(upload: claim.uploadID, path: path, size: params.size).message)
                await channel.finish()
                return
            case .binary:
                await channel.close(code: "proto.bad_record", message: "the upload is complete")
                return
            case .gap:
                continue
            case .closed:
                return
            }
        }
    }

    private func sendOpened(_ channel: MobileChannel, claim: UploadStaging.Claim, offset: UInt64) async -> Bool {
        let opened = FilesUploadOpenedParams(upload: claim.uploadID, offset: offset)
        guard let params = try? JSONValue(encoding: opened).objectValue else { return false }
        let frame = ChannelOpenedFrame(channel: channel.id, window: Self.window, params: params, resumed: offset > 0)
        return (try? await channel.send(frame: .channelOpened(frame))) != nil
    }

    private func refuse(_ channel: MobileChannel, _ error: MobileDaemonError) async {
        await channel.refuse(code: error.code, message: error.message, retryable: error.retryable,
                             details: error.code == "files.too_large" ? .object(["reason": .string(error.message)]) : nil)
    }

    static func write(_ data: Data, to fd: Int32, at offset: UInt64) -> Bool {
        data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let n = pwrite(fd, buffer.baseAddress! + written, buffer.count - written, off_t(offset) + off_t(written))
                guard n > 0 else { return false }
                written += n
            }
            return true
        }
    }
}
