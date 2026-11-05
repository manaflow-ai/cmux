/// The app's update of a Cloud machine too old to update in place (`CloudLegacyMachineUpdate` in the app runs the
/// fleet's guest upgrade through the Cloud API's exec) reads how its run ended from what the exec printed.
public nonisolated extension CloudExecResult {
    /// The last line of stdout: the guest script's result line.
    var lastLine: String { stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? "" }

    /// What a failure says: the result line, else the end of stderr.
    var failureDetail: String { lastLine.isEmpty ? String(stderr.suffix(400)) : lastLine }

    /// The guest script's result line (the last line of a wait's stdout) as a `link machine update` answer for the
    /// pinned build `commit`. No line yet, `running`, or an exec the provider ended (exit 124: the run may still go
    /// on) is `machine_update_unresolved`: the next wait asks again.
    func legacyUpdateAnswer(pinned commit: String) -> CloudMoveCLI.Answer {
        let line = lastLine
        func failed(_ code: String) -> CloudMoveCLI.Answer { CloudMoveCLI.Answer(ok: false, errorCode: code, error: failureDetail) }
        switch line.split(separator: " ").first.map(String.init) ?? "" {
        // UNVERIFIED: the new daemon serves and kept every host; only the terminal count was unreadable.
        // `OK already-current`: the daemon already ran the pinned build; nothing restarted.
        case "OK", "UNVERIFIED":
            return CloudMoveCLI.Answer(ok: true, updated: !line.hasPrefix("OK already-current"), build: commit)
        case "ROLLBACK":
            return failed("machine_update_rolled_back")
        case "FAIL":
            return failed("machine_update_failed")
        case "NOROOT":
            return failed("machine_update_unsupported")
        case "SKIP":
            // A daemon the fleet upgrade does not replace (no trusted carrier): not this way.
            if line.hasPrefix("SKIP unsupported-cloud-auth") { return failed("machine_update_unsupported") }
            // Between restarts of a crash-looping daemon: ask again later.
            if line.hasPrefix("SKIP no-daemon") { return failed("machine_unreachable") }
            // Another run holds the lock, too little disk, any other skip: nothing changed; ask
            // again later, never a failure kept for the build.
            return failed("machine_update_busy")
        default:
            if line.isEmpty || line == "running" || line.hasPrefix("PENDING") || exitCode == 124 { return failed("machine_update_unresolved") }
            return failed("machine_update_failed")
        }
    }
}
