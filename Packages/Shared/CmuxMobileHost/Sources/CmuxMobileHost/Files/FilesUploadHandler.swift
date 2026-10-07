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

    let configuration: MobileFilesConfiguration
    let roots: any MobileFileRootsProvider
    let staging: UploadStaging

    init(configuration: MobileFilesConfiguration, roots: any MobileFileRootsProvider, staging: UploadStaging) {
        self.configuration = configuration
        self.roots = roots
        self.staging = staging
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
        let policy = MobileFilePolicy(configuration: configuration, roots: await roots.roots(for: principal))
        let destination: MobileFilePolicy.Resolved
        let claim: UploadStaging.Claim
        do throws(MobileDaemonError) {
            switch params.dest.kind {
            case .terminal, .composer:
                destination = try policy.ensureInbox()
            case .path:
                guard let path = params.dest.path else {
                    throw MobileDaemonError(code: "files.dest_invalid", message: "dest.path is required")
                }
                destination = try policy.resolveWritableDirectory(path)
            }
            claim = try await staging.claim(install: principal.install, sha256: params.sha256, size: params.size)
        } catch {
            await refuse(channel, error)
            return
        }
        await receive(channel, params: params, claim: claim, destination: destination, gate: gate)
        await staging.release(claim)
    }

    private func receive(_ channel: MobileChannel, params: FilesUploadParams, claim: UploadStaging.Claim,
                         destination: MobileFilePolicy.Resolved, gate: MobileSessionGate) async {
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
        let opened = FilesUploadOpenedParams(upload: claim.uploadID, offset: length)
        guard let openedParams = try? JSONValue(encoding: opened).objectValue,
              (try? await channel.send(frame: .channelOpened(ChannelOpenedFrame(
                  channel: channel.id, window: Self.window, params: openedParams, resumed: length > 0)))) != nil else {
            return
        }
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
                guard Self.write(chunk.data, to: fd, at: length) else {
                    await channel.close(code: "owner.unreachable", message: "write failed")
                    return
                }
                length += UInt64(chunk.data.count)
            case .json(let value):
                if case .message(let message)? = try? MobileJSON(value: value), let end = FilesUploadEnd(message) {
                    await finish(channel, params: params, end: end, claim: claim, fd: fd, length: length,
                                 destination: destination)
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
                        claim: UploadStaging.Claim, fd: Int32, length: UInt64,
                        destination: MobileFilePolicy.Resolved) async {
        guard length == params.size else {
            await channel.close(code: "validation.invalid", message: "the upload ended at \(length) of \(params.size)")
            return
        }
        fsync(fd)
        let digest = FileDigest(descriptor: fd).sha256(length: length)
        guard let digest, digest == params.sha256, end.sha256 == params.sha256 else {
            unlink(claim.path)
            await channel.close(code: "files.digest_mismatch", message: "the bytes do not match sha256")
            return
        }
        let final: String
        do throws(MobileDaemonError) {
            final = try MobilePlacement(source: claim.path, directory: destination.path,
                                        name: MobileFilePolicy.sanitizedName(params.name)).place()
        } catch {
            await channel.close(code: error.code, message: error.message)
            return
        }
        let done = FilesUploadDone(upload: claim.uploadID, path: final, size: length)
        try? await channel.send(message: done.message)
        await channel.finish()
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
