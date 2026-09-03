import Darwin
import Foundation

/// Minimal self-exec mode that creates a private plugin process group before
/// replacing itself with a verified plugin entrypoint.
struct CmuxPluginProcessLauncherMode {
    private let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    /// Runs the launcher when its private marker is present.
    ///
    /// The supervisor passes the launch mode, containment marker, entrypoint,
    /// and (for scripts) interpreter arguments as process arguments. Standard
    /// output is the pinned entrypoint descriptor and standard error is the
    /// pinned interpreter descriptor, allowing this final child-side check to
    /// close the largest pathname replacement window before `execv`.
    ///
    /// - Returns: `nil` for a normal app launch, or a failure status when group
    ///   setup, marker acquisition, gate validation, or exec fails.
    func runIfRequested() -> Int32? {
        guard arguments.count >= 5,
              arguments[1] == "--cmux-plugin-launcher" else {
            return nil
        }
        guard setpgid(0, 0) == 0 else { return 126 }

        let mode = arguments[2]
        let markerPath = arguments[3]
        let entrypointPath = arguments[4]
        guard markerPath.hasPrefix("/"),
              entrypointPath.hasPrefix("/") else {
            return 126
        }

        let markerDescriptor = Darwin.open(
            markerPath,
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        )
        guard markerDescriptor >= 0 else { return 126 }
        guard Darwin.fcntl(markerDescriptor, F_SETFD, 0) == 0 else {
            Darwin.close(markerDescriptor)
            return 126
        }

        guard gateIsReady() else {
            Darwin.close(markerDescriptor)
            return 126
        }
        guard sameFile(STDOUT_FILENO, entrypointPath) else {
            Darwin.close(markerDescriptor)
            return 126
        }

        switch mode {
        case "executable":
            guard arguments.count == 5 else {
                Darwin.close(markerDescriptor)
                return 126
            }
            guard redirectStandardOutputAndError() else {
                Darwin.close(markerDescriptor)
                return 126
            }
            return exec(path: entrypointPath, arguments: [entrypointPath])

        case "interpreter":
            guard arguments.count >= 6 else {
                Darwin.close(markerDescriptor)
                return 126
            }
            let interpreterPath = arguments[5]
            guard interpreterPath.hasPrefix("/"),
                  sameFile(STDERR_FILENO, interpreterPath),
                  let scriptDescriptor = duplicateDescriptor(STDOUT_FILENO) else {
                Darwin.close(markerDescriptor)
                return 126
            }
            guard redirectStandardOutputAndError() else {
                Darwin.close(scriptDescriptor)
                Darwin.close(markerDescriptor)
                return 126
            }
            let interpreterArguments = Array(arguments.dropFirst(6))
            return exec(
                path: interpreterPath,
                arguments: [interpreterPath] + interpreterArguments + ["/dev/fd/\(scriptDescriptor)"]
            )

        default:
            Darwin.close(markerDescriptor)
            return 126
        }
    }

    private func gateIsReady() -> Bool {
        let expected = Array("cmux-ready\n".utf8)
        var received: [UInt8] = []
        received.reserveCapacity(expected.count)
        var buffer = [UInt8](repeating: 0, count: expected.count)
        while received.count < expected.count {
            let remaining = expected.count - received.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(STDIN_FILENO, bytes.baseAddress, min(bytes.count, remaining))
            }
            guard count > 0 else { return false }
            received.append(contentsOf: buffer.prefix(count))
        }
        return received == expected
    }

    private func duplicateDescriptor(_ descriptor: Int32) -> Int32? {
        let duplicated = Darwin.dup(descriptor)
        guard duplicated >= 0,
              Darwin.fcntl(duplicated, F_SETFD, 0) == 0 else {
            if duplicated >= 0 { Darwin.close(duplicated) }
            return nil
        }
        return duplicated
    }

    private func redirectStandardOutputAndError() -> Bool {
        let nullDescriptor = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullDescriptor >= 0,
              Darwin.dup2(nullDescriptor, STDOUT_FILENO) == STDOUT_FILENO,
              Darwin.dup2(nullDescriptor, STDERR_FILENO) == STDERR_FILENO else {
            if nullDescriptor >= 0 { Darwin.close(nullDescriptor) }
            return false
        }
        if nullDescriptor > STDERR_FILENO {
            Darwin.close(nullDescriptor)
        }
        return true
    }

    private func sameFile(_ descriptor: Int32, _ path: String) -> Bool {
        var descriptorMetadata = Darwin.stat()
        var pathMetadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0 else {
            return false
        }
        let statResult: Int32 = path.withCString { pointer in
            stat(pointer, &pathMetadata)
        }
        guard statResult == 0,
              (descriptorMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (pathMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return false
        }
        return descriptorMetadata.st_dev == pathMetadata.st_dev
            && descriptorMetadata.st_ino == pathMetadata.st_ino
    }

    private func exec(path: String, arguments: [String]) -> Int32 {
        let result: Int32 = withCStringArray(arguments) { argv in
            path.withCString { executablePath in
                Darwin.execv(executablePath, argv)
            }
        }
        return result == 0 ? 0 : 126
    }

    private func withCStringArray<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.dropLast().forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}
