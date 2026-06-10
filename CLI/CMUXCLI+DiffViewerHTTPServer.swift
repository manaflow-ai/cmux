import Darwin
import Foundation


// MARK: - Diff Viewer HTTP Server Lifecycle and Manifest
extension CMUXCLI {
    private static let diffViewerHTTPServerProtocolVersion = "wait-v2 remote-stream manifest-refresh react-app-v2 executable-bound"
    static let diffViewerHTTPServerHealthResponse = Data("ok \(diffViewerHTTPServerProtocolVersion)\n".utf8)

    func runDiffViewerServerCommand(commandArgs: [String]) throws {
        var rootPath: String?
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--root" {
                guard index + 1 < commandArgs.count else {
                    throw CLIError(message: "diff-viewer-server --root requires a path")
                }
                rootPath = commandArgs[index + 1]
                index += 2
                continue
            }
            throw CLIError(message: "Unexpected diff-viewer-server argument: \(arg)")
        }

        guard let rootPath else {
            throw CLIError(message: "diff-viewer-server requires --root")
        }

        let rootDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try validateSecureDiffViewerDirectory(rootDirectory, repairPermissions: false)
        try runDiffViewerHTTPServer(rootDirectory: rootDirectory)
    }

    func diffViewerHTTPServerOrigin(rootDirectory: URL, runtime: URL? = nil) throws -> URL {
        let rootDirectory = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        try validateSecureDiffViewerDirectory(rootDirectory, repairPermissions: false)

        if let state = try? readDiffViewerHTTPServerState(rootDirectory: rootDirectory),
           state.rootPath == rootDirectory.path,
           state.protocolVersion == Self.diffViewerHTTPServerProtocolVersion,
           (1...65535).contains(state.port),
           diffViewerHTTPServerStateMatchesRuntimeExecutable(state, runtime: runtime),
           diffViewerHTTPServerIsReachable(port: state.port) {
            guard let url = URL(string: "http://127.0.0.1:\(state.port)") else {
                throw CLIError(message: "Failed to build diff viewer server URL")
            }
            return url
        }

        return try startDiffViewerHTTPServer(rootDirectory: rootDirectory, runtime: runtime)
    }

    private func readDiffViewerHTTPServerState(rootDirectory: URL) throws -> DiffViewerHTTPServerState {
        let data = try Data(contentsOf: diffViewerHTTPServerStateURL(rootDirectory: rootDirectory))
        return try JSONDecoder().decode(DiffViewerHTTPServerState.self, from: data)
    }

    private func writeDiffViewerHTTPServerState(_ state: DiffViewerHTTPServerState, rootDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = diffViewerHTTPServerStateURL(rootDirectory: rootDirectory)
        try encoder.encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func diffViewerHTTPServerStateMatchesRuntimeExecutable(_ state: DiffViewerHTTPServerState, runtime: URL?) -> Bool {
        guard state.pid > 0,
              let currentExecutablePath = diffViewerExecutableURL(for: runtime)?.path,
              let serverExecutablePath = diffViewerHTTPServerExecutablePath(pid: state.pid),
              serverExecutablePath == currentExecutablePath else {
            return false
        }

        guard let recordedExecutablePath = state.executablePath else {
            return true
        }
        return recordedExecutablePath == currentExecutablePath
    }

    private func diffViewerHTTPServerExecutablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return proc_pidpath(pid, baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else {
            return nil
        }

        let rawPath = String(cString: buffer)
        if let resolvedPath = realpath(rawPath, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL.path
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    private func startDiffViewerHTTPServer(rootDirectory: URL, runtime: URL? = nil) throws -> URL {
        guard let executableURL = diffViewerExecutableURL(for: runtime) else {
            throw CLIError(message: "Failed to resolve cmux executable for diff viewer server")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["diff-viewer-server", "--root", rootDirectory.path]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullInput
        }
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullOutput
        }

        do {
            try process.run()
        } catch {
            throw CLIError(message: "Failed to start diff viewer server: \(error.localizedDescription)")
        }

        let port = try readDiffViewerHTTPServerPort(from: stdoutPipe.fileHandleForReading, process: process)
        guard diffViewerHTTPServerIsReachable(port: port) else {
            process.terminate()
            throw CLIError(message: "Diff viewer server did not become reachable")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CLIError(message: "Failed to build diff viewer server URL")
        }
        return url
    }

    private func readDiffViewerHTTPServerPort(from handle: FileHandle, process: Process) throws -> Int {
        let finished = DispatchSemaphore(value: 0)
        var result: Result<Int, Error>?

        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            while data.count < 64 {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty {
                    break
                }
                if byte == Data([0x0a]) {
                    break
                }
                data.append(byte)
            }

            let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let port = Int(line), (1...65535).contains(port) {
                result = .success(port)
            } else {
                result = .failure(CLIError(message: "Diff viewer server returned an invalid port"))
            }
            finished.signal()
        }

        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            throw CLIError(message: "Timed out starting diff viewer server")
        }

        switch result {
        case .success(let port):
            return port
        case .failure(let error):
            process.terminate()
            throw error
        case .none:
            process.terminate()
            throw CLIError(message: "Failed to read diff viewer server port")
        }
    }

    private func diffViewerHTTPServerIsReachable(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/__cmux_diff_viewer_healthz") else {
            return false
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let finished = DispatchSemaphore(value: 0)
        var reachable = false
        let task = session.dataTask(with: url) { data, response, _ in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            reachable = statusCode == 200 && data == Self.diffViewerHTTPServerHealthResponse
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            task.cancel()
            return false
        }
        return reachable
    }

    func writeDiffViewerHTTPManifest(
        token: String,
        files: [DiffViewerAllowedFile],
        rootDirectory: URL
    ) throws {
        guard diffViewerHTTPIsValidToken(token) else {
            throw CLIError(message: "Invalid diff viewer token")
        }
        guard !files.isEmpty, files.count <= 4096 else {
            throw CLIError(message: "Invalid diff viewer allowlist size")
        }
        let manifest = DiffViewerHTTPManifest(token: token, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = diffViewerHTTPManifestURL(token: token, rootDirectory: rootDirectory)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func runDiffViewerHTTPServer(rootDirectory: URL) throws -> Never {
        _ = signal(SIGPIPE, SIG_IGN)
        let serverFD = try bindDiffViewerHTTPServerSocket()
        let port = try diffViewerHTTPServerPort(fileDescriptor: serverFD)
        let manifestCache = DiffViewerHTTPManifestCache(owner: self, rootDirectory: rootDirectory)
        defer { close(serverFD) }

        try writeDiffViewerHTTPServerState(
            DiffViewerHTTPServerState(
                port: port,
                pid: getpid(),
                rootPath: rootDirectory.path,
                protocolVersion: Self.diffViewerHTTPServerProtocolVersion,
                executablePath: resolvedExecutableURL()?.path
            ),
            rootDirectory: rootDirectory
        )
        FileHandle.standardOutput.write(Data("\(port)\n".utf8))

        while true {
            let clientFD = accept(serverFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR {
                    continue
                }
                throw CLIError(message: "Diff viewer server accept failed: \(posixErrorMessage(errno))")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self.handleDiffViewerHTTPConnection(
                    fileDescriptor: clientFD,
                    port: port,
                    manifestCache: manifestCache
                )
            }
        }
    }

    final class DiffViewerHTTPManifestCache: @unchecked Sendable {
        private let owner: CMUXCLI
        private let rootDirectory: URL
        private let lock = NSLock()
        private var filesByToken: [String: [String: DiffViewerAllowedFile]] = [:]

        init(owner: CMUXCLI, rootDirectory: URL) {
            self.owner = owner
            self.rootDirectory = rootDirectory
        }

        func file(token: String, requestPath: String) throws -> DiffViewerAllowedFile? {
            lock.lock()
            if let files = filesByToken[token] {
                if let file = files[requestPath] {
                    lock.unlock()
                    return file
                }
                lock.unlock()
                let refreshedFiles = try owner.loadDiffViewerHTTPManifestFiles(token: token, rootDirectory: rootDirectory)
                lock.lock()
                filesByToken[token] = refreshedFiles
                let file = refreshedFiles[requestPath]
                lock.unlock()
                return file
            }
            lock.unlock()

            let files = try owner.loadDiffViewerHTTPManifestFiles(token: token, rootDirectory: rootDirectory)

            lock.lock()
            filesByToken[token] = files
            let file = files[requestPath]
            lock.unlock()
            return file
        }
    }

    private func bindDiffViewerHTTPServerSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CLIError(message: "Failed to create diff viewer server socket: \(posixErrorMessage(errno))")
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            close(fd)
            throw CLIError(message: "Failed to bind diff viewer server socket: \(posixErrorMessage(bindErrno))")
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            let listenErrno = errno
            close(fd)
            throw CLIError(message: "Failed to listen on diff viewer server socket: \(posixErrorMessage(listenErrno))")
        }

        return fd
    }

    private func diffViewerHTTPServerPort(fileDescriptor fd: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to inspect diff viewer server socket: \(posixErrorMessage(errno))")
        }
        return Int(in_port_t(bigEndian: address.sin_port))
    }

    func diffViewerAllowedFiles(
        pageURLs: [URL],
        assets: DiffViewerAssets,
        mapper: DiffViewerURLMapper,
        remotePatchURLsByPagePath: [String: URL] = [:]
    ) throws -> [DiffViewerAllowedFile] {
        var seen: Set<String> = []
        var files: [DiffViewerAllowedFile] = []

        func append(_ fileURL: URL, mimeType: String) throws {
            let standardizedPath = fileURL.standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else { return }
            files.append(try mapper.allowedFile(fileURL: fileURL, mimeType: mimeType))
        }

        for pageURL in pageURLs {
            try append(pageURL, mimeType: "text/html")
            let patchURL = diffViewerPatchFileURL(for: pageURL)
            if FileManager.default.fileExists(atPath: patchURL.path) {
                try append(patchURL, mimeType: "text/x-diff")
            } else if let remoteURL = remotePatchURLsByPagePath[pageURL.standardizedFileURL.path] {
                let standardizedPath = patchURL.standardizedFileURL.path
                guard seen.insert(standardizedPath).inserted else { continue }
                files.append(try mapper.allowedRemotePatchFile(fileURL: patchURL, remoteURL: remoteURL))
            }
        }
        for assetURL in assets.files {
            try append(assetURL, mimeType: "text/javascript")
        }
        return files
    }

    func diffViewerAllowedFilesWithExtraPage(
        _ pageURL: URL,
        files: [DiffViewerAllowedFile],
        mapper: DiffViewerURLMapper
    ) throws -> [DiffViewerAllowedFile] {
        let extra = try mapper.allowedFile(fileURL: pageURL, mimeType: "text/html")
        var seen: Set<String> = []
        var merged: [DiffViewerAllowedFile] = []
        for file in [extra] + files where seen.insert(file.requestPath).inserted {
            merged.append(file)
        }
        return merged
    }

    func remotePatchURLMap(pageURL: URL, remoteURL: URL?) -> [String: URL] {
        guard let remoteURL else { return [:] }
        return [pageURL.standardizedFileURL.path: remoteURL]
    }

}
