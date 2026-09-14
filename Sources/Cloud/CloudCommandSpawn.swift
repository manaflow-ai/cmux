import Darwin
import Foundation

/// Creates a stopped command in its own process group, transferring only its read endpoints.
struct CloudCommandSpawn {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32

    init(executable: URL, arguments: [String], input: Data?) throws {
        var descriptors: [Int32] = []
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        func makePipe() throws -> (Int32, Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw Self.error(errno) }
            descriptors += pair
            for fd in pair {
                guard fd > STDERR_FILENO, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw Self.error(EBADF)
                }
            }
            return (pair[0], pair[1])
        }
        let out = try makePipe()
        let err = try makePipe()
        let stdin: Int32?
        if let input {
            let pair = try makePipe()
            // The caller caps secret input at 1 KiB, below Darwin's pipe capacity.
            let written = input.withUnsafeBytes { Darwin.write(pair.1, $0.baseAddress, $0.count) }
            guard written == input.count else { throw Self.error(EIO) }
            Darwin.close(pair.1)
            descriptors.removeAll { $0 == pair.1 }
            stdin = pair.0
        } else {
            stdin = nil
        }
        var actions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            try Self.check(posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO))
        } else {
            try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try Self.check(posix_spawn_file_actions_adddup2(&actions, out.1, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, err.1, STDERR_FILENO))
        for fd in descriptors { try Self.check(posix_spawn_file_actions_addclose(&actions, fd)) }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // No setpgid-after-launch race; keep the leader stopped until its exit source is armed.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t()
        sigemptyset(&mask)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        sigfillset(&mask)
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &mask))
        let argv = [executable.path] + arguments
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        guard (argv + environment).allSatisfy({ !$0.utf8.contains(0) }) else { throw Self.error(EINVAL) }
        var child: pid_t = 0
        let status = Self.withStrings(argv) { argv in
            Self.withStrings(environment) { env in
                posix_spawn(&child, executable.path, &actions, &attributes, argv, env)
            }
        }
        try Self.check(status)
        pid = child
        stdout = out.0
        stderr = err.0
        descriptors.removeAll { $0 == out.0 || $0 == err.0 }
    }

    private static func check(_ status: Int32) throws {
        if status != 0 { throw error(status) }
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func withStrings<T>(
        _ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var strings = values.map { strdup($0) } + [nil]
        defer { strings.forEach { free($0) } }
        return strings.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
