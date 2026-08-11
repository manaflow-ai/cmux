internal import Darwin

private let terminalSurfaceFallbackLoginShellArguments = ["/bin/zsh", "-l"]
private let terminalSurfaceMinimumPasswordBufferCapacity = 16_384
private let terminalSurfaceMaximumPasswordBufferCapacity = 1_048_576

struct TerminalSurfaceLoginShellArgumentsResolver: Sendable {
    typealias PasswordRecordLookup = @Sendable () -> (name: String, shell: String)?

    private let passwordRecordLookup: PasswordRecordLookup

    init(_ passwordRecordLookup: @escaping PasswordRecordLookup) {
        self.passwordRecordLookup = passwordRecordLookup
    }

    func resolve() -> [String] {
        guard let record = passwordRecordLookup(), !record.shell.isEmpty else {
            return terminalSurfaceFallbackLoginShellArguments
        }
        guard !record.name.isEmpty else {
            return [record.shell, "-l"]
        }
        return [
            "/usr/bin/login", "-flp", record.name,
            "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \(record.shell)",
        ]
    }
}

func terminalSurfaceCurrentUserLoginShellArguments() -> [String] {
    TerminalSurfaceLoginShellArgumentsResolver(
        terminalSurfaceCurrentUserPasswordRecord
    ).resolve()
}

private func terminalSurfaceCurrentUserPasswordRecord() -> (name: String, shell: String)? {
    let suggestedCapacity = Int(sysconf(_SC_GETPW_R_SIZE_MAX))
    var capacity = max(
        suggestedCapacity,
        terminalSurfaceMinimumPasswordBufferCapacity
    )
    capacity = min(capacity, terminalSurfaceMaximumPasswordBufferCapacity)

    while capacity <= terminalSurfaceMaximumPasswordBufferCapacity {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: capacity)
        let status: Int32 = buffer.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return EINVAL }
            return getpwuid_r(
                getuid(),
                &record,
                baseAddress,
                buffer.count,
                &result
            )
        }
        if status == ERANGE,
           capacity < terminalSurfaceMaximumPasswordBufferCapacity {
            capacity = min(
                capacity * 2,
                terminalSurfaceMaximumPasswordBufferCapacity
            )
            continue
        }
        guard status == 0,
              result != nil,
              let namePointer = record.pw_name,
              let shellPointer = record.pw_shell else {
            return nil
        }
        return (
            name: String(cString: namePointer),
            shell: String(cString: shellPointer)
        )
    }
    return nil
}
