internal import CmuxTerminalBackend
internal import Darwin

func backendOnlyCurrentProcessInstanceToken(
    processID: pid_t
) -> BackendOnlyRendererWorkerProcessLookup {
    var info = proc_bsdinfo()
    let expectedSize = MemoryLayout<proc_bsdinfo>.stride
    errno = 0
    let size = proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(expectedSize)
    )
    if size == expectedSize, info.pbi_pid == UInt32(processID) {
        return .exact(BackendRendererProcessInstanceToken(
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        ))
    }
    if size <= 0, errno == ESRCH {
        return .missing
    }
    if size <= 0 {
        errno = 0
        if Darwin.kill(processID, 0) != 0, errno == ESRCH {
            return .missing
        }
    }
    return .unverifiable
}
