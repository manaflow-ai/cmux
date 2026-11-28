import Darwin
import Foundation

/// Keeps a private process group alive only while its launch-time owner exists.
/// This dedicated helper waits on kernel events, so app crashes cannot skip cleanup.
struct OwnedProcessSupervisor {
    private static let graceTimerIdentifier: UInt = 1
    /// Genuine shutdown grace deadline, delivered by EVFILT_TIMER rather than polling.
    private static let gracefulTerminationMilliseconds: Int = 1_000

    private let executablePath: String
    private let arguments: [String]
    private let usesParentLifetime: Bool

    init?(command: String, arguments: [String]) throws {
        guard command == "__owned-process-supervisor" || command == "__codex-teams-app-server-supervisor" else {
            return nil
        }
        usesParentLifetime = command == "__owned-process-supervisor"
        guard let executablePath = arguments.first, !executablePath.isEmpty else {
            throw CodexTeamsPOSIXSupport.error(operation: "missing target executable", code: EINVAL)
        }
        self.executablePath = executablePath
        self.arguments = Array(arguments.dropFirst())
    }

    func run() throws -> Int32 {
        let ownerPID = usesParentLifetime ? getppid() : nil
        guard ownerPID.map({ $0 > 1 }) ?? true else { throw POSIXError(.ESRCH) }
        let queue = kqueue()
        guard queue >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(queue) }
        // Keep the leader waitable so its group ID stays reserved until cleanup.
        _ = Darwin.signal(SIGCHLD, SIG_DFL)
        // Install signal ownership before starting the target. A signal to the
        // helper expires the lease; it must not strand the target by killing us.
        for signum in [SIGTERM, SIGINT, SIGHUP] {
            _ = Darwin.signal(signum, SIG_IGN)
            var event = kevent(ident: UInt(signum), filter: Int16(EVFILT_SIGNAL),
                              flags: UInt16(EV_ADD | EV_ENABLE), fflags: 0, data: 0, udata: nil)
            try Self.register(event: &event, queue: queue, operation: "register owner signal")
        }
        if let ownerPID {
            try Self.registerExit(processIdentifier: ownerPID, queue: queue)
        }
        let processIdentifier = try spawnTarget()
        do {
            if !usesParentLifetime {
                try Self.registerLifetime(fileDescriptor: STDIN_FILENO, queue: queue)
                try Self.registerLifetime(
                    fileDescriptor: CodexTeamsPOSIXSupport.watcherLifetimeFileDescriptor, queue: queue
                )
            }
            try Self.registerExit(processIdentifier: processIdentifier, queue: queue)
            // If the owner died before registration, never resume the target.
            // Parentage is kernel-owned and cannot be forged by inherited env.
            guard ownerPID == nil || getppid() == ownerPID else { throw POSIXError(.ESRCH) }
            guard Darwin.kill(processIdentifier, SIGCONT) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Self.decodedTerminationStatus(try Self.observe(
                processIdentifier: processIdentifier, queue: queue
            ))
        } catch {
            Self.forceTerminateAndReap(processIdentifier)
            throw error
        }
    }

    private func spawnTarget() throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try CodexTeamsPOSIXSupport.require(
            posix_spawn_file_actions_init(&fileActions),
            operation: "initialize target file actions"
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if usesParentLifetime {
            try CodexTeamsPOSIXSupport.require(
                posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO),
                operation: "inherit target stdin"
            )
        } else {
            try CodexTeamsPOSIXSupport.require(
            "/dev/null".withCString {
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    $0,
                    O_RDONLY,
                    0
                )
            },
            operation: "redirect target stdin"
            )
        }
        try CodexTeamsPOSIXSupport.require(
            posix_spawn_file_actions_addinherit_np(
                &fileActions,
                STDOUT_FILENO
            ),
            operation: "inherit target stdout"
        )
        try CodexTeamsPOSIXSupport.require(
            posix_spawn_file_actions_addinherit_np(
                &fileActions,
                STDERR_FILENO
            ),
            operation: "inherit target stderr"
        )

        var attributes: posix_spawnattr_t?
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_init(&attributes),
            operation: "initialize target attributes"
        )
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_START_SUSPENDED
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_setflags(&attributes, flags),
            operation: "configure target process group"
        )
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "configure target group leader"
        )

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signum in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaultSignals, signum) }
        var mask = sigset_t()
        sigemptyset(&mask)
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals), operation: "reset target signals"
        )
        try CodexTeamsPOSIXSupport.require(
            posix_spawnattr_setsigmask(&attributes, &mask), operation: "reset target signal mask"
        )

        let argv = [executablePath] + arguments
        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var processIdentifier: pid_t = 0
        let spawnStatus = try CodexTeamsPOSIXSupport.withCStringArray(argv) { argvPointer in
            try CodexTeamsPOSIXSupport.withCStringArray(environment) { environmentPointer in
                executablePath.withCString { executablePointer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        environmentPointer
                    )
                }
            }
        }
        guard spawnStatus == 0 else {
            throw CodexTeamsPOSIXSupport.error(operation: "launch target", code: spawnStatus)
        }
        guard processIdentifier > 1 else {
            throw CodexTeamsPOSIXSupport.error(operation: "launch target", code: EINVAL)
        }
        guard getpgid(processIdentifier) == processIdentifier else {
            _ = Darwin.kill(processIdentifier, SIGKILL)
            _ = Self.reap(processIdentifier)
            throw CodexTeamsPOSIXSupport.error(operation: "isolate target process group", code: EPERM)
        }
        return processIdentifier
    }

    private static func observe(
        processIdentifier: pid_t,
        queue: Int32
    ) throws -> Int32 {
        var terminationStarted = false
        var exitObserved = false
        var forceKillSent = false

        while true {
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, nil)
            if count < 0 {
                if errno == EINTR { continue }
                throw CodexTeamsPOSIXSupport.error(operation: "wait for supervisor event", code: errno)
            }
            guard count == 1 else { continue }
            if (event.flags & UInt16(EV_ERROR)) != 0 {
                throw CodexTeamsPOSIXSupport.error(
                    operation: "receive supervisor event",
                    code: event.data == 0 ? EIO : Int32(event.data)
                )
            }

            switch Int32(event.filter) {
            case EVFILT_READ:
                if !terminationStarted {
                    var byte: UInt8 = 0
                    let readResult = Darwin.read(Int32(event.ident), &byte, 1)
                    let didReachEOF = (event.flags & UInt16(EV_EOF)) != 0 || readResult == 0
                    guard didReachEOF else { continue }
                    terminationStarted = true
                    _ = Darwin.close(Int32(event.ident))
                    _ = Darwin.kill(-processIdentifier, SIGTERM)
                    try registerGraceTimer(queue: queue)
                }
            case EVFILT_PROC, EVFILT_SIGNAL:
                if Int32(event.filter) == EVFILT_PROC, event.ident == UInt(processIdentifier) {
                    exitObserved = true
                }
                if !terminationStarted {
                    terminationStarted = true
                    _ = Darwin.kill(-processIdentifier, SIGTERM)
                    try registerGraceTimer(queue: queue)
                }
            case EVFILT_TIMER:
                // Keep the leader unreaped until this deadline so its process
                // group id cannot be reused while descendants are cleaned up.
                forceKillSent = true
                _ = Darwin.kill(-processIdentifier, SIGKILL)
            default:
                continue
            }

            if exitObserved, !forceKillSent,
               Darwin.kill(-processIdentifier, 0) != 0,
               errno == ESRCH {
                return reap(processIdentifier)
            }
            if exitObserved, forceKillSent {
                return reap(processIdentifier)
            }
        }
    }

    private static func registerLifetime(
        fileDescriptor: Int32,
        queue: Int32
    ) throws {
        var event = kevent(
            ident: UInt(fileDescriptor),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: 0,
            data: 0,
            udata: nil
        )
        try register(event: &event, queue: queue, operation: "register lifetime")
    }

    private static func registerExit(
        processIdentifier: pid_t,
        queue: Int32
    ) throws {
        var event = kevent(
            ident: UInt(processIdentifier),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        try register(event: &event, queue: queue, operation: "register target exit")
    }

    private static func registerGraceTimer(queue: Int32) throws {
        var event = kevent(
            ident: graceTimerIdentifier,
            filter: Int16(EVFILT_TIMER),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0,
            data: gracefulTerminationMilliseconds,
            udata: nil
        )
        try register(event: &event, queue: queue, operation: "register termination deadline")
    }

    private static func register(
        event: inout kevent,
        queue: Int32,
        operation: String
    ) throws {
        while kevent(queue, &event, 1, nil, 0, nil) != 0 {
            if errno == EINTR { continue }
            throw CodexTeamsPOSIXSupport.error(operation: operation, code: errno)
        }
    }

    private static func forceTerminateAndReap(_ processIdentifier: pid_t) {
        guard processIdentifier > 1 else { return }
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        _ = reap(processIdentifier)
    }

    private static func reap(_ processIdentifier: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier { return status }
            if result == -1, errno == EINTR { continue }
            return -1
        }
    }

    private static func decodedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal == 0 {
            return (rawStatus >> 8) & 0xff
        }
        return 128 + signal
    }

}
