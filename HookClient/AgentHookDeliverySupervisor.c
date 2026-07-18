#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

enum {
    CMUX_SUPERVISOR_MAX_PAYLOAD_BYTES = 64 * 1024 * 1024,
    CMUX_SUPERVISOR_MAX_TIMEOUT_MILLISECONDS = 24 * 60 * 60 * 1000,
    CMUX_SUPERVISOR_GROUP_MEMBER_CAPACITY = 512,
    CMUX_SUPERVISOR_CENSUS_INTERVAL_MILLISECONDS = 1000,
};

typedef struct {
    uint64_t payload_bytes;
    uint64_t direct_timeout_milliseconds;
    uint64_t group_timeout_milliseconds;
    uint64_t termination_grace_milliseconds;
    char **child_arguments;
} CMUXSupervisorConfiguration;

static int64_t cmux_minimum_deadline(int64_t first, int64_t second);

static int64_t cmux_monotonic_milliseconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return -1;
    }
    if (now.tv_sec > INT64_MAX / 1000) {
        return INT64_MAX;
    }
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / (1000 * 1000);
}

static bool cmux_parse_unsigned(const char *raw, uint64_t maximum, uint64_t *value) {
    if (raw == NULL || raw[0] == '\0' || raw[0] == '-' || raw[0] == '+') {
        return false;
    }
    errno = 0;
    char *end = NULL;
    const unsigned long long parsed = strtoull(raw, &end, 10);
    if (errno != 0 || end == raw || end == NULL || *end != '\0' || parsed > maximum) {
        return false;
    }
    *value = (uint64_t)parsed;
    return true;
}

static bool cmux_parse_configuration(
    int argument_count,
    char **arguments,
    CMUXSupervisorConfiguration *configuration
) {
    if (argument_count < 11
        || strcmp(arguments[1], "--payload-bytes") != 0
        || strcmp(arguments[3], "--direct-timeout-ms") != 0
        || strcmp(arguments[5], "--group-timeout-ms") != 0
        || strcmp(arguments[7], "--termination-grace-ms") != 0
        || strcmp(arguments[9], "--") != 0
        || arguments[10] == NULL
        || arguments[10][0] == '\0') {
        return false;
    }
    return cmux_parse_unsigned(
            arguments[2],
            CMUX_SUPERVISOR_MAX_PAYLOAD_BYTES,
            &configuration->payload_bytes
        )
        && cmux_parse_unsigned(
            arguments[4],
            CMUX_SUPERVISOR_MAX_TIMEOUT_MILLISECONDS,
            &configuration->direct_timeout_milliseconds
        )
        && configuration->direct_timeout_milliseconds > 0
        && cmux_parse_unsigned(
            arguments[6],
            CMUX_SUPERVISOR_MAX_TIMEOUT_MILLISECONDS,
            &configuration->group_timeout_milliseconds
        )
        && configuration->group_timeout_milliseconds > 0
        && cmux_parse_unsigned(
            arguments[8],
            CMUX_SUPERVISOR_MAX_TIMEOUT_MILLISECONDS,
            &configuration->termination_grace_milliseconds
        )
        && configuration->termination_grace_milliseconds > 0
        && (configuration->child_arguments = &arguments[10]) != NULL;
}

static bool cmux_write_all(int descriptor, const void *raw_bytes, size_t count) {
    const unsigned char *bytes = raw_bytes;
    size_t offset = 0;
    while (offset < count) {
        const ssize_t written = write(descriptor, bytes + offset, count - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (written == 0) {
            return false;
        }
        offset += (size_t)written;
    }
    return true;
}

static bool cmux_emit_line(const char *kind, const char *detail, int64_t value) {
    char line[192] = {0};
    const int count = snprintf(
        line,
        sizeof(line),
        "CMUX-HOOK-SUPERVISOR 1 %s %s %lld\n",
        kind,
        detail,
        (long long)value
    );
    return count > 0
        && (size_t)count < sizeof(line)
        && cmux_write_all(STDOUT_FILENO, line, (size_t)count);
}

static bool cmux_emit_ready(pid_t supervisor, pid_t child) {
    char line[192] = {0};
    const int count = snprintf(
        line,
        sizeof(line),
        "CMUX-HOOK-SUPERVISOR 1 READY %d %d\n",
        supervisor,
        child
    );
    return count > 0
        && (size_t)count < sizeof(line)
        && cmux_write_all(STDOUT_FILENO, line, (size_t)count);
}

static void cmux_emit_launch_error(int error_number) {
    (void)cmux_emit_line("RESULT", "LAUNCH_ERROR", error_number);
    (void)close(STDOUT_FILENO);
}

static void cmux_discard_and_close(int descriptor) {
    if (descriptor < 0) {
        return;
    }
    (void)ftruncate(descriptor, 0);
    (void)close(descriptor);
}

static int cmux_create_payload_file(
    uint64_t payload_bytes,
    int64_t direct_deadline,
    int64_t group_deadline
) {
    char path[] = "/private/tmp/cmux-agent-hook-supervisor.XXXXXX";
    const int descriptor = mkstemp(path);
    if (descriptor < 0) {
        return -1;
    }
    if (unlink(path) != 0) {
        const int unlink_error = errno;
        cmux_discard_and_close(descriptor);
        (void)unlink(path);
        errno = unlink_error;
        return -1;
    }
    if (fchmod(descriptor, 0600) != 0) {
        const int chmod_error = errno;
        cmux_discard_and_close(descriptor);
        errno = chmod_error;
        return -1;
    }

    unsigned char buffer[16 * 1024] = {0};
    uint64_t remaining = payload_bytes;
    while (remaining > 0) {
        const int64_t now = cmux_monotonic_milliseconds();
        const int64_t deadline = cmux_minimum_deadline(direct_deadline, group_deadline);
        if (now < 0 || now >= deadline) {
            cmux_discard_and_close(descriptor);
            errno = now < 0 ? EIO : ETIMEDOUT;
            return -1;
        }
        const int64_t remaining_milliseconds = deadline - now;
        struct pollfd control = {
            .fd = STDIN_FILENO,
            .events = POLLIN | POLLHUP,
            .revents = 0,
        };
        const int poll_timeout = remaining_milliseconds > INT32_MAX
            ? INT32_MAX
            : (int)remaining_milliseconds;
        const int poll_result = poll(&control, 1, poll_timeout);
        if (poll_result < 0) {
            if (errno == EINTR) {
                continue;
            }
            const int poll_error = errno;
            cmux_discard_and_close(descriptor);
            errno = poll_error;
            return -1;
        }
        if (poll_result == 0) {
            cmux_discard_and_close(descriptor);
            errno = ETIMEDOUT;
            return -1;
        }
        const size_t requested = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
        const ssize_t received = read(STDIN_FILENO, buffer, requested);
        if (received < 0) {
            if (errno == EINTR) {
                continue;
            }
            const int read_error = errno;
            cmux_discard_and_close(descriptor);
            errno = read_error;
            return -1;
        }
        if (received == 0) {
            cmux_discard_and_close(descriptor);
            errno = ECANCELED;
            return -1;
        }
        if (!cmux_write_all(descriptor, buffer, (size_t)received)) {
            const int write_error = errno;
            cmux_discard_and_close(descriptor);
            errno = write_error == 0 ? EIO : write_error;
            return -1;
        }
        remaining -= (uint64_t)received;
    }
    if (lseek(descriptor, 0, SEEK_SET) != 0) {
        const int seek_error = errno;
        cmux_discard_and_close(descriptor);
        errno = seek_error;
        return -1;
    }
    return descriptor;
}

static void cmux_reset_child_signals(void) {
    const int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM};
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index += 1) {
        (void)signal(signals[index], SIG_DFL);
    }
}

static void cmux_exec_child(
    int payload_descriptor,
    int queue_descriptor,
    char **child_arguments,
    pid_t supervisor
) {
    cmux_reset_child_signals();
    if (dup2(payload_descriptor, STDIN_FILENO) < 0) {
        _exit(126);
    }
    const int null_descriptor = open("/dev/null", O_WRONLY | O_CLOEXEC);
    if (null_descriptor < 0 || dup2(null_descriptor, STDOUT_FILENO) < 0) {
        _exit(126);
    }
    if (null_descriptor != STDOUT_FILENO) {
        (void)close(null_descriptor);
    }
    if (payload_descriptor != STDIN_FILENO) {
        (void)close(payload_descriptor);
    }
    (void)close(queue_descriptor);

    char supervisor_text[32] = {0};
    const int count = snprintf(supervisor_text, sizeof(supervisor_text), "%d", supervisor);
    if (count <= 0 || (size_t)count >= sizeof(supervisor_text)
        || setenv("CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID", supervisor_text, 1) != 0) {
        _exit(126);
    }
    (void)unsetenv("CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP");
    execve(child_arguments[0], child_arguments, environ);
    _exit(errno == ENOENT ? 127 : 126);
}

static bool cmux_register_process_exit(int queue_descriptor, pid_t process) {
    struct kevent change = {0};
    EV_SET(
        &change,
        (uintptr_t)process,
        EVFILT_PROC,
        EV_ADD | EV_ENABLE | EV_CLEAR,
        NOTE_EXIT,
        0,
        NULL
    );
    if (kevent(queue_descriptor, &change, 1, NULL, 0, NULL) == 0) {
        return true;
    }
    return errno == ESRCH;
}

static bool cmux_group_snapshot(
    pid_t supervisor,
    pid_t *members,
    size_t capacity,
    size_t *visible_count,
    bool *truncated
) {
    const int count = proc_listpgrppids(
        supervisor,
        members,
        (int)(capacity * sizeof(members[0]))
    );
    if (count < 0) {
        return false;
    }
    *truncated = (size_t)count >= capacity;
    *visible_count = (size_t)count < capacity ? (size_t)count : capacity;
    return true;
}

static bool cmux_register_group_and_check_drained(int queue_descriptor, pid_t supervisor) {
    pid_t members[CMUX_SUPERVISOR_GROUP_MEMBER_CAPACITY] = {0};
    size_t visible_count = 0;
    bool truncated = false;
    if (!cmux_group_snapshot(
            supervisor,
            members,
            CMUX_SUPERVISOR_GROUP_MEMBER_CAPACITY,
            &visible_count,
            &truncated
        )) {
        return false;
    }

    bool has_other_member = truncated;
    for (size_t index = 0; index < visible_count; index += 1) {
        const pid_t member = members[index];
        if (member <= 0 || member == supervisor) {
            continue;
        }
        has_other_member = true;
        (void)cmux_register_process_exit(queue_descriptor, member);
    }
    if (has_other_member) {
        return false;
    }

    // Close the enumerate-to-wait race. If the group contained only the
    // supervisor in both snapshots, no other member remained that could fork.
    memset(members, 0, sizeof(members));
    visible_count = 0;
    truncated = false;
    if (!cmux_group_snapshot(
            supervisor,
            members,
            CMUX_SUPERVISOR_GROUP_MEMBER_CAPACITY,
            &visible_count,
            &truncated
        ) || truncated) {
        return false;
    }
    for (size_t index = 0; index < visible_count; index += 1) {
        if (members[index] > 0 && members[index] != supervisor) {
            (void)cmux_register_process_exit(queue_descriptor, members[index]);
            return false;
        }
    }
    return true;
}

static struct timespec cmux_timeout_until(int64_t deadline_milliseconds) {
    const int64_t now = cmux_monotonic_milliseconds();
    int64_t remaining = deadline_milliseconds - now;
    if (now < 0 || remaining < 0) {
        remaining = 0;
    }
    return (struct timespec) {
        .tv_sec = remaining / 1000,
        .tv_nsec = (remaining % 1000) * 1000 * 1000,
    };
}

static int64_t cmux_minimum_deadline(int64_t first, int64_t second) {
    return first < second ? first : second;
}

static bool cmux_control_requested_cancellation(void) {
    unsigned char bytes[64] = {0};
    for (;;) {
        const ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count > 0 || count == 0) {
            return true;
        }
        if (errno == EINTR) {
            continue;
        }
        return errno != EAGAIN && errno != EWOULDBLOCK;
    }
}

static void cmux_reap_if_exited(pid_t child, bool *child_reaped) {
    if (*child_reaped) {
        return;
    }
    int status = 0;
    const pid_t result = waitpid(child, &status, WNOHANG);
    if (result == child || (result < 0 && errno == ECHILD)) {
        *child_reaped = true;
    }
}

static void cmux_terminate_owned_group(
    int queue_descriptor,
    pid_t supervisor,
    pid_t child,
    bool child_reaped,
    uint64_t grace_milliseconds
) {
    (void)kill(-supervisor, SIGTERM);
    const int64_t now = cmux_monotonic_milliseconds();
    const int64_t grace_deadline = now < 0
        ? 0
        : now + (int64_t)grace_milliseconds;
    while (!cmux_register_group_and_check_drained(queue_descriptor, supervisor)) {
        cmux_reap_if_exited(child, &child_reaped);
        const int64_t current = cmux_monotonic_milliseconds();
        if (current < 0 || current >= grace_deadline) {
            break;
        }
        struct timespec timeout = cmux_timeout_until(grace_deadline);
        struct kevent events[16] = {0};
        const int event_count = kevent(
            queue_descriptor,
            NULL,
            0,
            events,
            (int)(sizeof(events) / sizeof(events[0])),
            &timeout
        );
        if (event_count < 0 && errno != EINTR) {
            break;
        }
    }
    cmux_reap_if_exited(child, &child_reaped);
    if (cmux_register_group_and_check_drained(queue_descriptor, supervisor)) {
        _exit(0);
    }
    (void)kill(-supervisor, SIGKILL);
    _exit(1);
}

static bool cmux_emit_direct_result(int status) {
    bool emitted = false;
    if (WIFEXITED(status)) {
        emitted = cmux_emit_line("RESULT", "EXIT", WEXITSTATUS(status));
    } else if (WIFSIGNALED(status)) {
        emitted = cmux_emit_line("RESULT", "SIGNAL", WTERMSIG(status));
    } else {
        emitted = cmux_emit_line("RESULT", "SIGNAL", 0);
    }
    (void)close(STDOUT_FILENO);
    return emitted;
}

int main(int argument_count, char **arguments) {
    CMUXSupervisorConfiguration configuration = {0};
    if (!cmux_parse_configuration(argument_count, arguments, &configuration)) {
        cmux_emit_launch_error(EINVAL);
        return 64;
    }

    (void)signal(SIGPIPE, SIG_IGN);
    const pid_t supervisor = getpid();
    // Foundation may spawn the executable as the leader of a fresh process
    // group. That group already has the identity property we need, and POSIX
    // deliberately rejects setsid() for a process-group leader. Otherwise,
    // create a new session so this live supervisor becomes the unique leader.
    if (getpgrp() != supervisor && setsid() < 0) {
        const int session_error = errno;
        cmux_emit_launch_error(session_error);
        return 70;
    }
    if (getpgrp() != supervisor) {
        cmux_emit_launch_error(EPERM);
        return 70;
    }

    const int64_t started = cmux_monotonic_milliseconds();
    if (started < 0) {
        cmux_emit_launch_error(EIO);
        return 70;
    }
    const int64_t direct_deadline = started + (int64_t)configuration.direct_timeout_milliseconds;
    const int64_t group_deadline = started + (int64_t)configuration.group_timeout_milliseconds;

    const int payload_descriptor = cmux_create_payload_file(
        configuration.payload_bytes,
        direct_deadline,
        group_deadline
    );
    if (payload_descriptor < 0) {
        const int payload_error = errno;
        if (payload_error == ECANCELED) {
            (void)cmux_emit_line("RESULT", "CANCELLED", 0);
            (void)close(STDOUT_FILENO);
            return 75;
        }
        if (payload_error == ETIMEDOUT) {
            (void)cmux_emit_line("RESULT", "TIMEOUT", 0);
            (void)close(STDOUT_FILENO);
            return 75;
        }
        cmux_emit_launch_error(payload_error);
        return 74;
    }
    const int64_t payload_finished = cmux_monotonic_milliseconds();
    if (payload_finished < 0
        || payload_finished >= cmux_minimum_deadline(direct_deadline, group_deadline)) {
        cmux_discard_and_close(payload_descriptor);
        if (payload_finished < 0) {
            cmux_emit_launch_error(EIO);
            return 70;
        }
        (void)cmux_emit_line("RESULT", "TIMEOUT", 0);
        (void)close(STDOUT_FILENO);
        return 75;
    }
    const int existing_flags = fcntl(STDIN_FILENO, F_GETFL);
    if (existing_flags < 0 || fcntl(STDIN_FILENO, F_SETFL, existing_flags | O_NONBLOCK) != 0) {
        const int control_error = errno;
        cmux_discard_and_close(payload_descriptor);
        cmux_emit_launch_error(control_error);
        return 74;
    }
    (void)fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC);
    (void)fcntl(STDOUT_FILENO, F_SETFD, FD_CLOEXEC);

    const int queue_descriptor = kqueue();
    if (queue_descriptor < 0) {
        const int queue_error = errno;
        cmux_discard_and_close(payload_descriptor);
        cmux_emit_launch_error(queue_error);
        return 71;
    }
    (void)fcntl(queue_descriptor, F_SETFD, FD_CLOEXEC);

    const int observed_signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM};
    struct kevent changes[1 + sizeof(observed_signals) / sizeof(observed_signals[0])] = {0};
    EV_SET(&changes[0], STDIN_FILENO, EVFILT_READ, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, NULL);
    for (size_t index = 0; index < sizeof(observed_signals) / sizeof(observed_signals[0]); index += 1) {
        (void)signal(observed_signals[index], SIG_IGN);
        EV_SET(
            &changes[index + 1],
            (uintptr_t)observed_signals[index],
            EVFILT_SIGNAL,
            EV_ADD | EV_ENABLE | EV_CLEAR,
            0,
            0,
            NULL
        );
    }
    if (kevent(
            queue_descriptor,
            changes,
            (int)(sizeof(changes) / sizeof(changes[0])),
            NULL,
            0,
            NULL
        ) != 0) {
        const int registration_error = errno;
        cmux_discard_and_close(payload_descriptor);
        (void)close(queue_descriptor);
        cmux_emit_launch_error(registration_error);
        return 71;
    }

    if (cmux_control_requested_cancellation()) {
        cmux_discard_and_close(payload_descriptor);
        (void)close(queue_descriptor);
        (void)cmux_emit_line("RESULT", "CANCELLED", 0);
        (void)close(STDOUT_FILENO);
        return 75;
    }
    const int64_t launch_ready = cmux_monotonic_milliseconds();
    if (launch_ready < 0
        || launch_ready >= cmux_minimum_deadline(direct_deadline, group_deadline)) {
        cmux_discard_and_close(payload_descriptor);
        (void)close(queue_descriptor);
        if (launch_ready < 0) {
            cmux_emit_launch_error(EIO);
            return 70;
        }
        (void)cmux_emit_line("RESULT", "TIMEOUT", 0);
        (void)close(STDOUT_FILENO);
        return 75;
    }

    const pid_t child = fork();
    if (child < 0) {
        const int fork_error = errno;
        cmux_discard_and_close(payload_descriptor);
        (void)close(queue_descriptor);
        cmux_emit_launch_error(fork_error);
        return 71;
    }
    if (child == 0) {
        cmux_exec_child(
            payload_descriptor,
            queue_descriptor,
            configuration.child_arguments,
            supervisor
        );
    }
    (void)close(payload_descriptor);
    (void)cmux_register_process_exit(queue_descriptor, child);

    if (!cmux_emit_ready(supervisor, child)) {
        cmux_terminate_owned_group(
            queue_descriptor,
            supervisor,
            child,
            false,
            configuration.termination_grace_milliseconds
        );
    }

    bool child_reaped = false;
    bool direct_result_emitted = false;

    for (;;) {
        if (!child_reaped) {
            int status = 0;
            const pid_t wait_result = waitpid(child, &status, WNOHANG);
            if (wait_result == child) {
                child_reaped = true;
                direct_result_emitted = true;
                if (!cmux_emit_direct_result(status)) {
                    cmux_terminate_owned_group(
                        queue_descriptor,
                        supervisor,
                        child,
                        child_reaped,
                        configuration.termination_grace_milliseconds
                    );
                }
            } else if (wait_result < 0 && errno != EINTR) {
                child_reaped = errno == ECHILD;
                direct_result_emitted = true;
                (void)cmux_emit_line("RESULT", "LAUNCH_ERROR", errno);
                (void)close(STDOUT_FILENO);
            }
        }

        if (direct_result_emitted
            && cmux_register_group_and_check_drained(queue_descriptor, supervisor)) {
            return 0;
        }

        const int64_t now = cmux_monotonic_milliseconds();
        if (now < 0) {
            if (!direct_result_emitted) {
                (void)cmux_emit_line("RESULT", "LAUNCH_ERROR", EIO);
                (void)close(STDOUT_FILENO);
            }
            cmux_terminate_owned_group(
                queue_descriptor,
                supervisor,
                child,
                child_reaped,
                configuration.termination_grace_milliseconds
            );
        }
        if (!direct_result_emitted && now >= direct_deadline) {
            (void)cmux_emit_line("RESULT", "TIMEOUT", 0);
            (void)close(STDOUT_FILENO);
            cmux_terminate_owned_group(
                queue_descriptor,
                supervisor,
                child,
                child_reaped,
                configuration.termination_grace_milliseconds
            );
        }
        if (now >= group_deadline) {
            if (!direct_result_emitted) {
                (void)cmux_emit_line("RESULT", "TIMEOUT", 0);
                (void)close(STDOUT_FILENO);
            }
            cmux_terminate_owned_group(
                queue_descriptor,
                supervisor,
                child,
                child_reaped,
                configuration.termination_grace_milliseconds
            );
        }

        int64_t wake_deadline = now + CMUX_SUPERVISOR_CENSUS_INTERVAL_MILLISECONDS;
        wake_deadline = cmux_minimum_deadline(wake_deadline, group_deadline);
        if (!direct_result_emitted) {
            wake_deadline = cmux_minimum_deadline(wake_deadline, direct_deadline);
        }
        struct timespec timeout = cmux_timeout_until(wake_deadline);
        struct kevent events[16] = {0};
        const int event_count = kevent(
            queue_descriptor,
            NULL,
            0,
            events,
            (int)(sizeof(events) / sizeof(events[0])),
            &timeout
        );
        if (event_count < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (!direct_result_emitted) {
                (void)cmux_emit_line("RESULT", "LAUNCH_ERROR", errno);
                (void)close(STDOUT_FILENO);
            }
            cmux_terminate_owned_group(
                queue_descriptor,
                supervisor,
                child,
                child_reaped,
                configuration.termination_grace_milliseconds
            );
        }
        for (int index = 0; index < event_count; index += 1) {
            if (events[index].filter == EVFILT_SIGNAL
                || (events[index].filter == EVFILT_READ
                    && events[index].ident == STDIN_FILENO
                    && cmux_control_requested_cancellation())) {
                if (!direct_result_emitted) {
                    (void)cmux_emit_line("RESULT", "CANCELLED", 0);
                    (void)close(STDOUT_FILENO);
                }
                cmux_terminate_owned_group(
                    queue_descriptor,
                    supervisor,
                    child,
                    child_reaped,
                    configuration.termination_grace_milliseconds
                );
            }
        }
    }
}
