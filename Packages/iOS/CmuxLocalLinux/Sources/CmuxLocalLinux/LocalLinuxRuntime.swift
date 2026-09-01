#if canImport(IshKernel)
public import Foundation
internal import IshKernel

/// Errors from booting or driving the on-device iSH Linux kernel.
public enum LocalLinuxError: Error, Equatable, Sendable {
    case rootfsAssetMissing
    case rootfsImportFailed(String)
    case bootFailed(errno: Int32)
    case sessionOpenFailed(errno: Int32)
    case notBooted
}

/// Process-wide owner of the embedded iSH kernel (vendor/ish).
///
/// The kernel has one global process table, so there is exactly one runtime
/// per app process. All kernel entry points are serialized on one utility
/// queue; sessions stream output on kernel threads into `AsyncStream`s.
public final class LocalLinuxRuntime: @unchecked Sendable {
    public static let shared = LocalLinuxRuntime()

    private let queue = DispatchQueue(label: "ai.manaflow.cmux.local-linux", qos: .userInitiated)
    private var bootResult: Result<Void, LocalLinuxError>?

    /// Where the imported Alpine fakefs lives across launches.
    public static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalLinux/alpine", isDirectory: true)
    }

    /// The bundled Alpine minirootfs tarball (see scripts/build-ish-ios.sh).
    public static func bundledRootfsURL() -> URL? {
        Bundle.module.url(forResource: "alpine-rootfs", withExtension: "tar.gz")
    }

    /// Boots the kernel once: imports the bundled rootfs on first launch,
    /// mounts it, and starts init. Subsequent calls return the first result.
    public func bootIfNeeded(
        rootURL: URL = LocalLinuxRuntime.defaultRootURL(),
        rootfsArchiveURL: URL? = LocalLinuxRuntime.bundledRootfsURL()
    ) throws {
        try queue.sync {
            if let bootResult {
                return try bootResult.get()
            }
            let result = Result<Void, LocalLinuxError> {
                try Self.bootLocked(rootURL: rootURL, rootfsArchiveURL: rootfsArchiveURL)
            }.mapError { $0 as! LocalLinuxError }
            bootResult = result
            return try result.get()
        }
    }

    private static func bootLocked(rootURL: URL, rootfsArchiveURL: URL?) throws {
        let fileManager = FileManager.default
        let dataURL = rootURL.appendingPathComponent("data", isDirectory: true)
        if !fileManager.fileExists(atPath: dataURL.path) {
            guard let archive = rootfsArchiveURL else {
                throw LocalLinuxError.rootfsAssetMissing
            }
            try fileManager.createDirectory(at: rootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var errBuf = [CChar](repeating: 0, count: 1024)
            let ok = archive.path.withCString { tarPath in
                dataURL.path.withCString { destPath in
                    cmux_ish_import_rootfs(tarPath, destPath, &errBuf, errBuf.count)
                }
            }
            guard ok else {
                let message = String(cString: errBuf)
                try? fileManager.removeItem(at: dataURL)
                throw LocalLinuxError.rootfsImportFailed(message)
            }
        }
        let rc = dataURL.path.withCString { cmux_ish_boot($0, nil) }
        guard rc == 0 else {
            throw LocalLinuxError.bootFailed(errno: rc)
        }
    }

    /// Opens one emulated terminal session (default: `/bin/login -f root`,
    /// matching iSH's launch command).
    public func openSession(
        command: [String] = ["/bin/login", "-f", "root"],
        environment: [String] = ["TERM=xterm-256color", "HOME=/root", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
        columns: Int,
        rows: Int
    ) throws -> LocalLinuxSession {
        try queue.sync {
            guard case .some(.success) = bootResult else {
                throw LocalLinuxError.notBooted
            }
            return try LocalLinuxSession(
                command: command,
                environment: environment,
                columns: columns,
                rows: rows
            )
        }
    }
}

/// One emulated pty + session leader inside the local kernel.
public final class LocalLinuxSession: @unchecked Sendable {
    /// Raw slave-side output bytes, in write order. Finishes on hangup.
    public let output: AsyncStream<Data>
    public let processID: Int32

    private let handle: Int32
    private let sink: LocalLinuxOutputSink
    private let continuation: AsyncStream<Data>.Continuation

    fileprivate init(
        command: [String],
        environment: [String],
        columns: Int,
        rows: Int
    ) throws {
        var continuation: AsyncStream<Data>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        self.sink = LocalLinuxOutputSink(continuation: continuation)

        let context = Unmanaged.passRetained(sink).toOpaque()
        let handle = withCStringArray(command) { argv in
            withCStringArray(environment) { envp in
                cmux_ish_session_open(argv, envp, Int32(columns), Int32(rows), { context, bytes, length in
                    guard let context, let bytes, length > 0 else { return }
                    let sink = Unmanaged<LocalLinuxOutputSink>.fromOpaque(context).takeUnretainedValue()
                    sink.emit(Data(bytes: bytes, count: length))
                }, context)
            }
        }
        guard handle >= 0 else {
            Unmanaged<LocalLinuxOutputSink>.fromOpaque(context).release()
            continuation.finish()
            throw LocalLinuxError.sessionOpenFailed(errno: handle)
        }
        self.handle = handle
        self.processID = cmux_ish_session_pid(handle)
    }

    /// Sends input bytes (keyboard/paste) to the tty. Returns bytes accepted.
    @discardableResult
    public func send(_ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return 0 }
            return Int(cmux_ish_session_input(handle, base, raw.count))
        }
    }

    public func resize(columns: Int, rows: Int) {
        cmux_ish_session_resize(handle, Int32(columns), Int32(rows))
    }

    /// SIGHUPs the session and finishes the output stream.
    public func hangup() {
        cmux_ish_session_hangup(handle)
        continuation.finish()
    }
}

/// Boxed continuation handed to the C callback as an unmanaged context.
private final class LocalLinuxOutputSink: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }
}

/// Calls `body` with a NULL-terminated array of C string pointers.
private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    cStrings.append(nil)
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
            body($0)
        }
    }
}
#endif
