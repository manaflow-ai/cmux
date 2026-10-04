import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Darwin
import Foundation

/// Opens browser-proxy streams as pipe-backed `ssh -W host:port` channels on
/// the already authenticated ssh-tmux ControlMaster.
///
/// Unlike a dynamic `ssh -D` forward, this has no second loopback TCP
/// listener. The only locally reachable socket is the credentialed browser
/// listener; every outbound SSH channel is represented by file descriptors
/// owned by this process.
final class RemoteTmuxSSHStreamClient: RemoteProxyStreamOpening, @unchecked Sendable {
    private static let maxPendingWriteBytes = 4 * 1024 * 1024

    private final class Stream {
        let process: Process
        let input: DispatchIO
        let output: DispatchIO

        init(process: Process, input: DispatchIO, output: DispatchIO) {
            self.process = process
            self.input = input
            self.output = output
        }
    }

    private let host: RemoteTmuxHost
    private let sshExecutablePath: String
    private let controlPersistSeconds: Int
    private let ioQueue = DispatchQueue(
        label: "com.cmuxterm.app.remote-tmux.browser-proxy-stream-io",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var streams: [String: Stream] = [:]
    private var pendingWriteBytesByStream: [String: Int] = [:]

    init(host: RemoteTmuxHost, sshExecutablePath: String, controlPersistSeconds: Int) {
        self.host = host
        self.sshExecutablePath = sshExecutablePath
        self.controlPersistSeconds = controlPersistSeconds
    }

    func openStream(host targetHost: String, port: Int, timeoutMs: Int) throws -> String {
        guard !targetHost.isEmpty, (1...65_535).contains(port) else {
            throw RemoteTmuxError.launchFailed("browser proxy target is invalid")
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let timeoutSeconds = max(1, (max(timeoutMs, 1) + 999) / 1_000)
        process.arguments = host.sshControlArguments(
            controlPersistSeconds: controlPersistSeconds,
            batchMode: true
        ) + [
            "-o", "ConnectTimeout=\(timeoutSeconds)",
            "-W", "\(targetHost):\(port)",
            "--", host.destination,
        ]

        do {
            try process.run()
        } catch {
            throw RemoteTmuxError.launchFailed("browser proxy SSH channel failed to launch: \(error.localizedDescription)")
        }

        // `Pipe` owns its FileHandles and closes their descriptors when they
        // are released. Give `DispatchIO` close-on-exec duplicates instead,
        // then close the Pipe-owned parent ends so each descriptor has one
        // owner. Sharing either original descriptor would allow a delayed
        // FileHandle cleanup to close a descriptor the kernel has reused.
        let inputFD = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard inputFD >= 0 else {
            process.terminate()
            throw RemoteTmuxError.launchFailed(
                "browser proxy failed to duplicate SSH input: \(String(cString: strerror(errno)))"
            )
        }
        let outputFD = fcntl(outputPipe.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard outputFD >= 0 else {
            Darwin.close(inputFD)
            process.terminate()
            throw RemoteTmuxError.launchFailed(
                "browser proxy failed to duplicate SSH output: \(String(cString: strerror(errno)))"
            )
        }
        do {
            try inputPipe.fileHandleForWriting.close()
            try outputPipe.fileHandleForReading.close()
        } catch {
            Darwin.close(inputFD)
            Darwin.close(outputFD)
            process.terminate()
            throw RemoteTmuxError.launchFailed(
                "browser proxy failed to transfer SSH pipe ownership: \(error.localizedDescription)"
            )
        }
        let input = DispatchIO(type: .stream, fileDescriptor: inputFD, queue: ioQueue) { _ in
            Darwin.close(inputFD)
        }
        let output = DispatchIO(type: .stream, fileDescriptor: outputFD, queue: ioQueue) { _ in
            Darwin.close(outputFD)
        }
        input.setLimit(lowWater: 1)
        output.setLimit(lowWater: 1)

        let streamID = UUID().uuidString
        stateLock.lock()
        streams[streamID] = Stream(process: process, input: input, output: output)
        stateLock.unlock()
        return streamID
    }

    func writeStream(streamID: String, data: Data) throws {
        guard !data.isEmpty else { return }
        guard let stream = stream(for: streamID) else {
            throw RemoteTmuxError.unreachable("browser proxy stream \(streamID) is not open")
        }
        try reservePendingWriteBytes(streamID: streamID, count: data.count)
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        stream.input.write(offset: 0, data: dispatchData, queue: ioQueue) { [weak self] done, _, _ in
            guard done else { return }
            self?.releasePendingWriteBytes(streamID: streamID, count: data.count)
        }
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (RemoteDaemonStreamEvent) -> Void
    ) throws {
        guard let stream = stream(for: streamID) else {
            throw RemoteTmuxError.unreachable("browser proxy stream \(streamID) is not open")
        }
        stream.output.read(offset: 0, length: .max, queue: ioQueue) { done, data, error in
            if error != 0 {
                let detail = String(cString: strerror(error))
                queue.async { onEvent(.error(detail)) }
                return
            }
            let payload = data.map { Data($0) } ?? Data()
            if done {
                queue.async { onEvent(.eof(payload)) }
            } else if !payload.isEmpty {
                queue.async { onEvent(.data(payload)) }
            }
        }
    }

    func closeStream(streamID: String) {
        let stream: Stream?
        stateLock.lock()
        stream = streams.removeValue(forKey: streamID)
        pendingWriteBytesByStream.removeValue(forKey: streamID)
        stateLock.unlock()

        guard let stream else { return }
        stream.input.close(flags: .stop)
        stream.output.close(flags: .stop)
        if stream.process.isRunning {
            stream.process.terminate()
        }
    }

    private func stream(for streamID: String) -> Stream? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streams[streamID]
    }

    private func reservePendingWriteBytes(streamID: String, count: Int) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        let pending = pendingWriteBytesByStream[streamID, default: 0]
        guard pending + count <= Self.maxPendingWriteBytes else {
            throw RemoteTmuxError.unreachable(
                "browser proxy stream \(streamID) exceeded \(Self.maxPendingWriteBytes) pending write bytes"
            )
        }
        pendingWriteBytesByStream[streamID] = pending + count
    }

    private func releasePendingWriteBytes(streamID: String, count: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let pending = pendingWriteBytesByStream[streamID] else { return }
        pendingWriteBytesByStream[streamID] = max(0, pending - count)
    }
}
