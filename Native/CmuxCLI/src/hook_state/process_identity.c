// Keep Darwin's kinfo_proc layout in the SDK that defines it. This small shim
// lets the Rust hook-state port query the same snapshot as AgentPIDProcessIdentity.
#include <stdint.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>

int cmux_cli_process_snapshot(pid_t pid, int64_t *start_seconds,
                              int64_t *start_microseconds, int64_t *parent_pid) {
    if (pid <= 0) {
        return 0;
    }

    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0 ||
        info.kp_proc.p_pid != pid || info.kp_proc.p_stat == SZOMB) {
        return 0;
    }

    *start_seconds = (int64_t)info.kp_proc.p_un.__p_starttime.tv_sec;
    *start_microseconds = (int64_t)info.kp_proc.p_un.__p_starttime.tv_usec;
    *parent_pid = (int64_t)info.kp_eproc.e_ppid;
    return 1;
}
