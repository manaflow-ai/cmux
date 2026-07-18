#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

enum {
    CMUX_HOOK_MAX_PAYLOAD_BYTES = 8 * 1024 * 1024,
    CMUX_HOOK_MAX_ENVIRONMENT_BYTES = 256 * 1024,
    CMUX_HOOK_MAX_ENVIRONMENT_VALUE_BYTES = 128 * 1024,
    CMUX_HOOK_ATTEMPTS = 3,
    CMUX_HOOK_ATTEMPT_TIMEOUT_MILLISECONDS = 350,
    CMUX_HOOK_FALLBACK_TIMEOUT_MILLISECONDS = 500,
    CMUX_HOOK_TERMINATION_GRACE_MILLISECONDS = 50,
};

typedef struct {
    unsigned char *bytes;
    size_t count;
    size_t capacity;
} CMUXBuffer;

static const char *const cmux_hook_environment_keys[] = {
    "HOME",
    "PATH",
    "PWD",
    "TMPDIR",
    "CODEX_HOME",
    "CMUX_AGENT_HOOK_STATE_DIR",
    "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
    "CMUX_AGENT_LAUNCH_ARGV_B64",
    "CMUX_AGENT_LAUNCH_CWD",
    "CMUX_AGENT_LAUNCH_EXECUTABLE",
    "CMUX_AGENT_LAUNCH_KIND",
    "CMUX_AGENT_MANAGED_SUBAGENT",
    "CMUX_BUNDLE_ID",
    "CMUX_CODEX_PID",
    "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
    "CMUX_SURFACE_ID",
    "CMUX_TAG",
    "CMUX_WORKSPACE_ID",
    "CMUX_SOCKET_PATH",
    NULL,
};

static bool cmux_buffer_reserve(CMUXBuffer *buffer, size_t additional) {
    if (additional > SIZE_MAX - buffer->count) {
        return false;
    }
    const size_t required = buffer->count + additional;
    if (required <= buffer->capacity) {
        return true;
    }
    size_t capacity = buffer->capacity == 0 ? 4096 : buffer->capacity;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }
    unsigned char *bytes = realloc(buffer->bytes, capacity);
    if (bytes == NULL) {
        return false;
    }
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return true;
}

static bool cmux_buffer_append(CMUXBuffer *buffer, const void *bytes, size_t count) {
    if (!cmux_buffer_reserve(buffer, count)) {
        return false;
    }
    if (count > 0) {
        memcpy(buffer->bytes + buffer->count, bytes, count);
        buffer->count += count;
    }
    return true;
}

static bool cmux_buffer_append_string(CMUXBuffer *buffer, const char *string) {
    if (string == NULL) {
        return false;
    }
    return cmux_buffer_append(buffer, string, strlen(string));
}

static void cmux_buffer_destroy(CMUXBuffer *buffer) {
    free(buffer->bytes);
    buffer->bytes = NULL;
    buffer->count = 0;
    buffer->capacity = 0;
}

static void cmux_drain_stdin(void) {
    unsigned char bytes[4096];
    for (;;) {
        const ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count > 0) {
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

static bool cmux_read_stdin(CMUXBuffer *payload) {
    while (payload->count < CMUX_HOOK_MAX_PAYLOAD_BYTES) {
        const size_t remaining = CMUX_HOOK_MAX_PAYLOAD_BYTES - payload->count;
        const size_t chunk = remaining < 64 * 1024 ? remaining : 64 * 1024;
        if (!cmux_buffer_reserve(payload, chunk)) {
            cmux_drain_stdin();
            return false;
        }
        const ssize_t count = read(STDIN_FILENO, payload->bytes + payload->count, chunk);
        if (count > 0) {
            payload->count += (size_t)count;
            continue;
        }
        if (count == 0) {
            return true;
        }
        if (errno != EINTR) {
            return false;
        }
    }

    unsigned char extra = 0;
    for (;;) {
        const ssize_t count = read(STDIN_FILENO, &extra, 1);
        if (count == 0) {
            return true;
        }
        if (count > 0) {
            cmux_drain_stdin();
            return false;
        }
        if (errno != EINTR) {
            return false;
        }
    }
}

static char *cmux_base64_encode(const unsigned char *input, size_t count) {
    static const char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    if (count > (SIZE_MAX - 1) / 4 * 3) {
        return NULL;
    }
    const size_t output_count = ((count + 2) / 3) * 4;
    char *output = malloc(output_count + 1);
    if (output == NULL) {
        return NULL;
    }

    size_t input_index = 0;
    size_t output_index = 0;
    while (input_index + 2 < count) {
        const uint32_t value = ((uint32_t)input[input_index] << 16)
            | ((uint32_t)input[input_index + 1] << 8)
            | (uint32_t)input[input_index + 2];
        output[output_index++] = alphabet[(value >> 18) & 0x3F];
        output[output_index++] = alphabet[(value >> 12) & 0x3F];
        output[output_index++] = alphabet[(value >> 6) & 0x3F];
        output[output_index++] = alphabet[value & 0x3F];
        input_index += 3;
    }
    if (input_index < count) {
        uint32_t value = (uint32_t)input[input_index] << 16;
        output[output_index++] = alphabet[(value >> 18) & 0x3F];
        if (input_index + 1 < count) {
            value |= (uint32_t)input[input_index + 1] << 8;
            output[output_index++] = alphabet[(value >> 12) & 0x3F];
            output[output_index++] = alphabet[(value >> 6) & 0x3F];
            output[output_index++] = '=';
        } else {
            output[output_index++] = alphabet[(value >> 12) & 0x3F];
            output[output_index++] = '=';
            output[output_index++] = '=';
        }
    }
    output[output_index] = '\0';
    return output;
}

static const char *cmux_hook_subcommand(const char *executable_path) {
    const char *name = strrchr(executable_path, '/');
    name = name == NULL ? executable_path : name + 1;
    static const char prefix[] = "cmux-codex-hook-";
    if (strncmp(name, prefix, sizeof(prefix) - 1) != 0) {
        return NULL;
    }
    name += sizeof(prefix) - 1;

    static const char *const subcommands[] = {
        "session-start",
        "prompt-submit",
        "stop",
        "pre-tool-use",
        "post-tool-use",
        "notification",
        NULL,
    };
    for (size_t index = 0; subcommands[index] != NULL; index += 1) {
        const size_t length = strlen(subcommands[index]);
        if (strncmp(name, subcommands[index], length) == 0
            && (name[length] == '\0' || strcmp(name + length, ".sh") == 0)) {
            return subcommands[index];
        }
    }
    return NULL;
}

static bool cmux_delivery_id_is_valid(const char *delivery_id) {
    const size_t count = strlen(delivery_id);
    if (count == 0 || count > 256) {
        return false;
    }
    for (size_t index = 0; index < count; index += 1) {
        const unsigned char byte = (unsigned char)delivery_id[index];
        if (!(isalnum(byte) || byte == '.' || byte == '_' || byte == ':' || byte == '-')) {
            return false;
        }
    }
    return true;
}

static bool cmux_pid_string_is_valid(const char *pid) {
    if (pid == NULL || pid[0] == '\0') {
        return false;
    }
    for (size_t index = 0; pid[index] != '\0'; index += 1) {
        if (!isdigit((unsigned char)pid[index])) {
            return false;
        }
    }
    return true;
}

static const char *cmux_resolve_agent_pid(char storage[32]) {
    const char *pid = getenv("CMUX_CODEX_PID");
    if (cmux_pid_string_is_valid(pid)) {
        return pid;
    }
    snprintf(storage, 32, "%d", getppid());
    setenv("CMUX_CODEX_PID", storage, 1);
    return storage;
}

static const char *cmux_resolve_delivery_id(
    const char *subcommand,
    const char *agent_pid,
    char storage[320]
) {
    const char *inherited = getenv("CMUX_AGENT_HOOK_DELIVERY_ID");
    if (inherited != NULL && cmux_delivery_id_is_valid(inherited)) {
        return inherited;
    }
    uint64_t nonce = 0;
    arc4random_buf(&nonce, sizeof(nonce));
    snprintf(
        storage,
        320,
        "codex-%s-%s-%d-%016llx",
        agent_pid,
        subcommand,
        getpid(),
        (unsigned long long)nonce
    );
    setenv("CMUX_AGENT_HOOK_DELIVERY_ID", storage, 1);
    return storage;
}

static bool cmux_build_environment(CMUXBuffer *environment) {
    for (size_t index = 0; cmux_hook_environment_keys[index] != NULL; index += 1) {
        const char *key = cmux_hook_environment_keys[index];
        const char *value = getenv(key);
        if (value == NULL) {
            continue;
        }
        const size_t key_count = strlen(key);
        const size_t value_count = strnlen(value, CMUX_HOOK_MAX_ENVIRONMENT_VALUE_BYTES + 1);
        if (value_count > CMUX_HOOK_MAX_ENVIRONMENT_VALUE_BYTES) {
            return false;
        }
        const size_t additional = key_count + 1 + value_count + 1;
        if (additional > CMUX_HOOK_MAX_ENVIRONMENT_BYTES - environment->count) {
            return false;
        }
        const unsigned char zero = 0;
        if (!cmux_buffer_append(environment, key, key_count)
            || !cmux_buffer_append(environment, &zero, 1)
            || !cmux_buffer_append(environment, value, value_count)
            || !cmux_buffer_append(environment, &zero, 1)) {
            return false;
        }
    }
    return true;
}

static bool cmux_capability_is_valid(const char *capability) {
    if (capability == NULL || capability[0] == '\0') {
        return false;
    }
    for (size_t index = 0; capability[index] != '\0'; index += 1) {
        if (isspace((unsigned char)capability[index])) {
            return false;
        }
    }
    return true;
}

static bool cmux_build_request(
    CMUXBuffer *request,
    const char *delivery_id,
    const char *subcommand,
    const char *payload_base64,
    const char *environment_base64,
    const char *capability
) {
    return cmux_buffer_append_string(request, "_cmux_capability_v1 ")
        && cmux_buffer_append_string(request, capability)
        && cmux_buffer_append_string(request, " {\"id\":\"hook-")
        && cmux_buffer_append_string(request, delivery_id)
        && cmux_buffer_append_string(
            request,
            "\",\"method\":\"agent.hook.enqueue\",\"params\":{\"delivery_id\":\""
        )
        && cmux_buffer_append_string(request, delivery_id)
        && cmux_buffer_append_string(request, "\",\"agent\":\"codex\",\"subcommand\":\"")
        && cmux_buffer_append_string(request, subcommand)
        && cmux_buffer_append_string(request, "\",\"payload_b64\":\"")
        && cmux_buffer_append_string(request, payload_base64)
        && cmux_buffer_append_string(request, "\",\"environment_b64\":\"")
        && cmux_buffer_append_string(request, environment_base64)
        && cmux_buffer_append_string(request, "\"}}\n");
}

static int64_t cmux_monotonic_milliseconds(void) {
    struct timespec time = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
        return 0;
    }
    return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static bool cmux_wait_for_socket(int socket_fd, short events, int64_t deadline) {
    for (;;) {
        const int64_t now = cmux_monotonic_milliseconds();
        const int64_t remaining = deadline - now;
        if (remaining <= 0) {
            return false;
        }
        struct pollfd descriptor = {
            .fd = socket_fd,
            .events = events,
            .revents = 0,
        };
        const int result = poll(&descriptor, 1, remaining > INT32_MAX ? INT32_MAX : (int)remaining);
        if (result > 0) {
            return (descriptor.revents & (events | POLLHUP)) != 0
                && (descriptor.revents & (POLLERR | POLLNVAL)) == 0;
        }
        if (result == 0) {
            return false;
        }
        if (errno != EINTR) {
            return false;
        }
    }
}

static int cmux_connect_unix_socket(const char *path, int64_t deadline) {
    if (path == NULL || path[0] != '/') {
        return -1;
    }
    const size_t path_count = strlen(path);
    struct sockaddr_un address = {0};
    if (path_count >= sizeof(address.sun_path)) {
        return -1;
    }
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, path_count + 1);
#if defined(__APPLE__)
    address.sun_len = (uint8_t)(offsetof(struct sockaddr_un, sun_path) + path_count + 1);
#endif

    const int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        return -1;
    }
    fcntl(socket_fd, F_SETFD, FD_CLOEXEC);
    const int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(socket_fd);
        return -1;
    }
#if defined(__APPLE__)
    const int no_sigpipe = 1;
    setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
#endif

    const socklen_t address_length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_count + 1);
    if (connect(socket_fd, (const struct sockaddr *)&address, address_length) != 0) {
        if (errno != EINPROGRESS || !cmux_wait_for_socket(socket_fd, POLLOUT, deadline)) {
            close(socket_fd);
            return -1;
        }
        int socket_error = 0;
        socklen_t error_length = sizeof(socket_error);
        if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &socket_error, &error_length) != 0
            || socket_error != 0) {
            close(socket_fd);
            return -1;
        }
    }
    return socket_fd;
}

static bool cmux_write_all(int socket_fd, const unsigned char *bytes, size_t count, int64_t deadline) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t written = write(socket_fd, bytes + offset, count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
            && cmux_wait_for_socket(socket_fd, POLLOUT, deadline)) {
            continue;
        }
        return false;
    }
    return true;
}

static bool cmux_read_queued_ack(int socket_fd, int64_t deadline) {
    char response[16 * 1024];
    size_t count = 0;
    while (count + 1 < sizeof(response)) {
        const ssize_t read_count = read(socket_fd, response + count, sizeof(response) - count - 1);
        if (read_count > 0) {
            count += (size_t)read_count;
            response[count] = '\0';
            if (memchr(response, '\n', count) != NULL) {
                return strstr(response, "\"ok\":true") != NULL
                    && strstr(response, "\"queued\":true") != NULL;
            }
            continue;
        }
        if (read_count == 0) {
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        if ((errno == EAGAIN || errno == EWOULDBLOCK)
            && cmux_wait_for_socket(socket_fd, POLLIN, deadline)) {
            continue;
        }
        return false;
    }
    return false;
}

static bool cmux_submit_request(const char *socket_path, const CMUXBuffer *request) {
    for (int attempt = 0; attempt < CMUX_HOOK_ATTEMPTS; attempt += 1) {
        const int64_t deadline = cmux_monotonic_milliseconds()
            + CMUX_HOOK_ATTEMPT_TIMEOUT_MILLISECONDS;
        const int socket_fd = cmux_connect_unix_socket(socket_path, deadline);
        if (socket_fd < 0) {
            continue;
        }
        const bool succeeded = cmux_write_all(socket_fd, request->bytes, request->count, deadline)
            && cmux_read_queued_ack(socket_fd, deadline);
        close(socket_fd);
        if (succeeded) {
            return true;
        }
    }
    return false;
}

static bool cmux_write_all_fd(int descriptor, const unsigned char *bytes, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t written = write(descriptor, bytes + offset, count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

static bool cmux_write_all_fd_until(
    int descriptor,
    const unsigned char *bytes,
    size_t count,
    int64_t deadline
) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t written = write(descriptor, bytes + offset, count - offset);
        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
            && cmux_wait_for_socket(descriptor, POLLOUT, deadline)) {
            continue;
        }
        return false;
    }
    return true;
}

static bool cmux_reap_child_until(pid_t child, int64_t deadline) {
    for (;;) {
        int status = 0;
        const pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) {
            return true;
        }
        if (result < 0 && errno != EINTR) {
            return false;
        }

        const int64_t now = cmux_monotonic_milliseconds();
        if (now >= deadline) {
            return false;
        }
        const int64_t remaining = deadline - now;
        const int64_t sleep_milliseconds = remaining < 5 ? remaining : 5;
        struct timespec sleep_time = {
            .tv_sec = 0,
            .tv_nsec = sleep_milliseconds * 1000 * 1000,
        };
        while (nanosleep(&sleep_time, &sleep_time) != 0 && errno == EINTR) {}
    }
}

static void cmux_terminate_and_reap_child(pid_t child) {
    if (kill(-child, SIGTERM) != 0 && errno == ESRCH) {
        (void)cmux_reap_child_until(child, cmux_monotonic_milliseconds() + 1);
        return;
    }
    const int64_t grace_deadline = cmux_monotonic_milliseconds()
        + CMUX_HOOK_TERMINATION_GRACE_MILLISECONDS;
    if (cmux_reap_child_until(child, grace_deadline)) {
        return;
    }

    (void)kill(-child, SIGKILL);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}

static void cmux_run_cli_fallback(
    const char *subcommand,
    const char *socket_path,
    const CMUXBuffer *payload
) {
    const char *cli = getenv("CMUX_BUNDLED_CLI_PATH");
    const bool use_path_search = cli == NULL || cli[0] == '\0' || access(cli, X_OK) != 0;
    if (use_path_search) {
        cli = "cmux";
    }

    int input_pipe[2] = {-1, -1};
    if (pipe(input_pipe) != 0) {
        return;
    }
    const int write_flags = fcntl(input_pipe[1], F_GETFL, 0);
    if (write_flags < 0 || fcntl(input_pipe[1], F_SETFL, write_flags | O_NONBLOCK) != 0) {
        close(input_pipe[0]);
        close(input_pipe[1]);
        return;
    }
    const int null_fd = open("/dev/null", O_RDWR);
    if (null_fd < 0) {
        close(input_pipe[0]);
        close(input_pipe[1]);
        return;
    }

    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        close(null_fd);
        close(input_pipe[0]);
        close(input_pipe[1]);
        return;
    }
    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(null_fd);
        close(input_pipe[0]);
        close(input_pipe[1]);
        return;
    }
    if (posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP) != 0
        || posix_spawnattr_setpgroup(&attributes, 0) != 0) {
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        close(null_fd);
        close(input_pipe[0]);
        close(input_pipe[1]);
        return;
    }
    posix_spawn_file_actions_adddup2(&actions, input_pipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, null_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, null_fd, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, input_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, input_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, null_fd);

    char *arguments_with_socket[] = {
        (char *)cli,
        "--socket",
        (char *)socket_path,
        "hooks",
        "codex",
        "enqueue",
        (char *)subcommand,
        NULL,
    };
    char *arguments_without_socket[] = {
        (char *)cli,
        "hooks",
        "codex",
        "enqueue",
        (char *)subcommand,
        NULL,
    };
    char **arguments = socket_path != NULL && socket_path[0] != '\0'
        ? arguments_with_socket
        : arguments_without_socket;

    pid_t child = 0;
    const int spawn_status = use_path_search
        ? posix_spawnp(&child, cli, &actions, &attributes, arguments, environ)
        : posix_spawn(&child, cli, &actions, &attributes, arguments, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(input_pipe[0]);
    close(null_fd);
    if (spawn_status != 0) {
        close(input_pipe[1]);
        return;
    }

    const int64_t deadline = cmux_monotonic_milliseconds()
        + CMUX_HOOK_FALLBACK_TIMEOUT_MILLISECONDS;
    const bool wrote_payload = cmux_write_all_fd_until(
        input_pipe[1],
        payload->bytes,
        payload->count,
        deadline
    );
    close(input_pipe[1]);
    if (!wrote_payload || !cmux_reap_child_until(child, deadline)) {
        cmux_terminate_and_reap_child(child);
    }
}

static void cmux_print_noop(void) {
    static const char response[] = "{}\n";
    cmux_write_all_fd(STDOUT_FILENO, (const unsigned char *)response, sizeof(response) - 1);
}

int main(int argument_count, char **arguments) {
    (void)argument_count;
    signal(SIGPIPE, SIG_IGN);

    const char *subcommand = cmux_hook_subcommand(arguments[0]);
    if (subcommand == NULL) {
        cmux_drain_stdin();
        cmux_print_noop();
        return 0;
    }

    CMUXBuffer payload = {0};
    if (!cmux_read_stdin(&payload)) {
        cmux_buffer_destroy(&payload);
        cmux_print_noop();
        return 0;
    }

    const char *surface_id = getenv("CMUX_SURFACE_ID");
    const char *disabled = getenv("CMUX_CODEX_HOOKS_DISABLED");
    if (surface_id == NULL || surface_id[0] == '\0' || (disabled != NULL && strcmp(disabled, "1") == 0)) {
        cmux_buffer_destroy(&payload);
        cmux_print_noop();
        return 0;
    }

    char agent_pid_storage[32] = {0};
    const char *agent_pid = cmux_resolve_agent_pid(agent_pid_storage);
    char delivery_id_storage[320] = {0};
    const char *delivery_id = cmux_resolve_delivery_id(
        subcommand,
        agent_pid,
        delivery_id_storage
    );

    CMUXBuffer environment = {0};
    const bool environment_succeeded = cmux_build_environment(&environment);
    char *payload_base64 = cmux_base64_encode(payload.bytes, payload.count);
    char *environment_base64 = environment_succeeded
        ? cmux_base64_encode(environment.bytes, environment.count)
        : NULL;
    const char *socket_path = getenv("CMUX_SOCKET_PATH");
    const char *capability = getenv("CMUX_SOCKET_CAPABILITY");
    bool delivered = false;
    CMUXBuffer request = {0};
    if (payload_base64 != NULL
        && environment_base64 != NULL
        && socket_path != NULL
        && cmux_capability_is_valid(capability)
        && cmux_build_request(
            &request,
            delivery_id,
            subcommand,
            payload_base64,
            environment_base64,
            capability
        )) {
        delivered = cmux_submit_request(socket_path, &request);
    }

    if (!delivered) {
        cmux_run_cli_fallback(subcommand, socket_path, &payload);
    }

    cmux_buffer_destroy(&request);
    free(environment_base64);
    free(payload_base64);
    cmux_buffer_destroy(&environment);
    cmux_buffer_destroy(&payload);
    cmux_print_noop();
    return 0;
}
