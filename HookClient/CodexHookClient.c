#include <ctype.h>
#include <dirent.h>
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
    CMUX_HOOK_FOREGROUND_TIMEOUT_MILLISECONDS = 35,
    CMUX_HOOK_WORKER_RETRY_ATTEMPTS = 2,
    CMUX_HOOK_WORKER_ATTEMPT_TIMEOUT_MILLISECONDS = 350,
    CMUX_HOOK_FALLBACK_TIMEOUT_MILLISECONDS = 500,
    CMUX_HOOK_EMERGENCY_FALLBACK_TIMEOUT_MILLISECONDS = 50,
    CMUX_HOOK_TERMINATION_GRACE_MILLISECONDS = 50,
};

typedef enum {
    CMUX_SUBMISSION_RETRYABLE,
    CMUX_SUBMISSION_QUEUED,
    CMUX_SUBMISSION_HANDOFF_UNACKNOWLEDGED,
    CMUX_SUBMISSION_UNSUPPORTED,
    CMUX_SUBMISSION_REJECTED,
} CMUXSubmissionResult;

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
    "CMUX_CUSTOM_CLAUDE_PATH",
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

static bool cmux_hook_filename_suffix_is_valid(const char *suffix) {
    if (suffix[0] == '\0' || strcmp(suffix, ".sh") == 0) {
        return true;
    }
    if (suffix[0] != '-') {
        return false;
    }

    suffix += 1;
    size_t hash_count = 0;
    while (isxdigit((unsigned char)suffix[hash_count])) {
        hash_count += 1;
    }
    if (hash_count < 8) {
        return false;
    }
    return suffix[hash_count] == '\0' || strcmp(suffix + hash_count, ".sh") == 0;
}

static const char *cmux_hook_subcommand(const char *executable_path) {
    const char *name = strrchr(executable_path, '/');
    name = name == NULL ? executable_path : name + 1;
    static const char native_prefix[] = "cmux-codex-native-hook-";
    static const char legacy_prefix[] = "cmux-codex-hook-";
    if (strncmp(name, native_prefix, sizeof(native_prefix) - 1) == 0) {
        name += sizeof(native_prefix) - 1;
    } else if (strncmp(name, legacy_prefix, sizeof(legacy_prefix) - 1) == 0) {
        name += sizeof(legacy_prefix) - 1;
    } else {
        return NULL;
    }

    static const struct {
        const char *filename_tag;
        const char *subcommand;
    } hooks[] = {
        {"session-start", "session-start"},
        {"prompt-submit", "prompt-submit"},
        {"stop", "stop"},
        {"pre-tool-use", "pre-tool-use"},
        {"post-tool-use", "post-tool-use"},
        {"notification", "notification"},
        {"feed-PreToolUse", "feed:PreToolUse"},
        {"feed-PermissionRequest", "feed:PermissionRequest"},
        {"feed-PostToolUse", "feed:PostToolUse"},
        {"feed-PreCompact", "feed:PreCompact"},
        {"feed-PostCompact", "feed:PostCompact"},
        {"feed-SubagentStart", "feed:SubagentStart"},
        {"feed-SubagentStop", "feed:SubagentStop"},
        {NULL, NULL},
    };
    for (size_t index = 0; hooks[index].filename_tag != NULL; index += 1) {
        const size_t length = strlen(hooks[index].filename_tag);
        if (strncmp(name, hooks[index].filename_tag, length) == 0
            && cmux_hook_filename_suffix_is_valid(name + length)) {
            return hooks[index].subcommand;
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

static bool cmux_hook_environment_key_is_allowed(const char *key, size_t key_count) {
    if (key_count < 5 || strncmp(key, "CMUX_", 5) != 0) {
        // The app-side shared policy admits only selected provider and launch
        // variables. Forwarding non-CMUX values here lets that policy evolve
        // without duplicating every provider key in this C client.
        return true;
    }
    for (size_t index = 0; cmux_hook_environment_keys[index] != NULL; index += 1) {
        const char *allowed = cmux_hook_environment_keys[index];
        if (strlen(allowed) == key_count && memcmp(key, allowed, key_count) == 0) {
            return true;
        }
    }
    return false;
}

static bool cmux_build_environment(CMUXBuffer *environment) {
    for (char **entry = environ; entry != NULL && *entry != NULL; entry += 1) {
        const char *separator = strchr(*entry, '=');
        if (separator == NULL) {
            continue;
        }
        const char *key = *entry;
        const size_t key_count = (size_t)(separator - key);
        if (key_count == 0 || key_count > 128
            || !cmux_hook_environment_key_is_allowed(key, key_count)) {
            continue;
        }
        const char *value = separator + 1;
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

static bool cmux_socket_peer_matches_uid(int socket_fd, uid_t expected_uid) {
    uid_t peer_uid = 0;
    gid_t peer_gid = 0;
    return getpeereid(socket_fd, &peer_uid, &peer_gid) == 0
        && peer_uid == expected_uid;
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
    if (!cmux_socket_peer_matches_uid(socket_fd, geteuid())) {
        close(socket_fd);
        return -1;
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

static const char *cmux_json_value_start(const char *json, const char *key) {
    char quoted_key[128];
    const int count = snprintf(quoted_key, sizeof(quoted_key), "\"%s\"", key);
    if (count <= 0 || (size_t)count >= sizeof(quoted_key)) {
        return NULL;
    }
    const char *cursor = json;
    while ((cursor = strstr(cursor, quoted_key)) != NULL) {
        cursor += (size_t)count;
        while (isspace((unsigned char)*cursor)) {
            cursor += 1;
        }
        if (*cursor != ':') {
            continue;
        }
        cursor += 1;
        while (isspace((unsigned char)*cursor)) {
            cursor += 1;
        }
        return cursor;
    }
    return NULL;
}

static bool cmux_json_boolean_value_is(const char *json, const char *key, bool expected) {
    const char *value = cmux_json_value_start(json, key);
    if (value == NULL) {
        return false;
    }
    const char *literal = expected ? "true" : "false";
    const size_t count = strlen(literal);
    return strncmp(value, literal, count) == 0
        && !isalnum((unsigned char)value[count])
        && value[count] != '_';
}

static bool cmux_json_string_value_is(const char *json, const char *key, const char *expected) {
    const char *value = cmux_json_value_start(json, key);
    if (value == NULL || *value != '"') {
        return false;
    }
    value += 1;
    const size_t count = strlen(expected);
    return strncmp(value, expected, count) == 0 && value[count] == '"';
}

static CMUXSubmissionResult cmux_classify_queued_response(const char *response) {
    if (cmux_json_boolean_value_is(response, "ok", true)
        && cmux_json_boolean_value_is(response, "queued", true)) {
        return CMUX_SUBMISSION_QUEUED;
    }
    if (!cmux_json_boolean_value_is(response, "ok", false)) {
        return CMUX_SUBMISSION_RETRYABLE;
    }
    if (cmux_json_string_value_is(response, "code", "method_not_found")
        || cmux_json_string_value_is(response, "code", "unrecognized_method")) {
        return CMUX_SUBMISSION_UNSUPPORTED;
    }
    if (cmux_json_string_value_is(response, "code", "hook_queue_unavailable")) {
        return CMUX_SUBMISSION_RETRYABLE;
    }
    return CMUX_SUBMISSION_REJECTED;
}

static CMUXSubmissionResult cmux_read_queued_ack(int socket_fd, int64_t deadline) {
    char response[16 * 1024];
    size_t count = 0;
    while (count + 1 < sizeof(response)) {
        const ssize_t read_count = read(socket_fd, response + count, sizeof(response) - count - 1);
        if (read_count > 0) {
            count += (size_t)read_count;
            response[count] = '\0';
            if (memchr(response, '\n', count) != NULL) {
                return cmux_classify_queued_response(response);
            }
            continue;
        }
        if (read_count == 0) {
            return CMUX_SUBMISSION_RETRYABLE;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (cmux_wait_for_socket(socket_fd, POLLIN, deadline)) {
                continue;
            }
            // The complete request already reached the local Unix socket.
            // Closing our side leaves those bytes readable after EOF, so the
            // app retains ownership even when its durable ack misses this
            // foreground deadline. Retrying every such handoff would create a
            // fork/CLI storm precisely while the app is overloaded.
            if (cmux_monotonic_milliseconds() >= deadline) {
                return CMUX_SUBMISSION_HANDOFF_UNACKNOWLEDGED;
            }
        }
        return CMUX_SUBMISSION_RETRYABLE;
    }
    return CMUX_SUBMISSION_RETRYABLE;
}

static CMUXSubmissionResult cmux_submit_request(
    const char *socket_path,
    const CMUXBuffer *request,
    int attempts,
    int attempt_timeout_milliseconds
) {
    for (int attempt = 0; attempt < attempts; attempt += 1) {
        const int64_t deadline = cmux_monotonic_milliseconds()
            + attempt_timeout_milliseconds;
        const int socket_fd = cmux_connect_unix_socket(socket_path, deadline);
        if (socket_fd < 0) {
            continue;
        }
        CMUXSubmissionResult result = CMUX_SUBMISSION_RETRYABLE;
        if (cmux_write_all(socket_fd, request->bytes, request->count, deadline)) {
            result = cmux_read_queued_ack(socket_fd, deadline);
        }
        close(socket_fd);
        if (result != CMUX_SUBMISSION_RETRYABLE) {
            return result;
        }
    }
    return CMUX_SUBMISSION_RETRYABLE;
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

static bool cmux_process_group_exists(pid_t group) {
    if (kill(-group, 0) == 0) {
        return true;
    }
    return errno == EPERM;
}

static bool cmux_wait_for_process_group_exit_until(pid_t group, int64_t deadline) {
    while (cmux_process_group_exists(group)) {
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
    return true;
}

static void cmux_terminate_and_reap_child(pid_t child) {
    if (kill(-child, SIGTERM) != 0 && errno == ESRCH) {
        (void)cmux_reap_child_until(child, cmux_monotonic_milliseconds() + 1);
        return;
    }
    const int64_t grace_deadline = cmux_monotonic_milliseconds()
        + CMUX_HOOK_TERMINATION_GRACE_MILLISECONDS;
    const bool child_reaped = cmux_reap_child_until(child, grace_deadline);
    const bool group_exited = cmux_wait_for_process_group_exit_until(child, grace_deadline);
    if (!group_exited) {
        (void)kill(-child, SIGKILL);
    }

    if (!child_reaped) {
        int status = 0;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    if (!group_exited) {
        (void)cmux_wait_for_process_group_exit_until(
            child,
            cmux_monotonic_milliseconds() + CMUX_HOOK_TERMINATION_GRACE_MILLISECONDS
        );
    }
}

static void cmux_run_cli_fallback(
    const char *subcommand,
    const char *socket_path,
    const CMUXBuffer *payload,
    bool use_legacy_entrypoint,
    int timeout_milliseconds
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
    short spawn_flags = POSIX_SPAWN_SETPGROUP;
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    spawn_flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (posix_spawnattr_setflags(&attributes, spawn_flags) != 0
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
    char *legacy_arguments_with_socket[] = {
        (char *)cli,
        "--socket",
        (char *)socket_path,
        "hooks",
        "codex",
        (char *)subcommand,
        NULL,
    };
    char *legacy_arguments_without_socket[] = {
        (char *)cli,
        "hooks",
        "codex",
        (char *)subcommand,
        NULL,
    };
    const bool is_feed = strncmp(subcommand, "feed:", 5) == 0 && subcommand[5] != '\0';
    char *legacy_feed_arguments_with_socket[] = {
        (char *)cli,
        "--socket",
        (char *)socket_path,
        "hooks",
        "feed",
        "--source",
        "codex",
        "--event",
        (char *)(subcommand + 5),
        NULL,
    };
    char *legacy_feed_arguments_without_socket[] = {
        (char *)cli,
        "hooks",
        "feed",
        "--source",
        "codex",
        "--event",
        (char *)(subcommand + 5),
        NULL,
    };
    const bool has_socket = socket_path != NULL && socket_path[0] != '\0';
    char **arguments;
    if (use_legacy_entrypoint && is_feed) {
        arguments = has_socket
            ? legacy_feed_arguments_with_socket
            : legacy_feed_arguments_without_socket;
    } else if (use_legacy_entrypoint) {
        arguments = has_socket
            ? legacy_arguments_with_socket
            : legacy_arguments_without_socket;
    } else {
        arguments = has_socket ? arguments_with_socket : arguments_without_socket;
    }

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
        + timeout_milliseconds;
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

static void cmux_close_inherited_worker_descriptors(void) {
    DIR *directory = opendir("/dev/fd");
    if (directory != NULL) {
        const int directory_fd = dirfd(directory);
        struct dirent *entry = NULL;
        while ((entry = readdir(directory)) != NULL) {
            char *end = NULL;
            errno = 0;
            const long raw_descriptor = strtol(entry->d_name, &end, 10);
            if (errno != 0 || end == entry->d_name || *end != '\0'
                || raw_descriptor < 3 || raw_descriptor > INT32_MAX
                || raw_descriptor == directory_fd) {
                continue;
            }
            close((int)raw_descriptor);
        }
        closedir(directory);
        return;
    }

    // `/dev/fd` is present on supported macOS releases. Keep a complete
    // fallback for degraded environments instead of capping the scan and
    // leaking an arbitrarily high inherited descriptor.
    const int limit = getdtablesize();
    for (int descriptor = 3; descriptor < limit; descriptor += 1) {
        close(descriptor);
    }
}

static void cmux_redirect_standard_descriptors_to_null(void) {
    const int null_fd = open("/dev/null", O_RDWR);
    if (null_fd < 0) {
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        return;
    }
    const bool succeeded = dup2(null_fd, STDIN_FILENO) >= 0
        && dup2(null_fd, STDOUT_FILENO) >= 0
        && dup2(null_fd, STDERR_FILENO) >= 0;
    if (null_fd > STDERR_FILENO) {
        close(null_fd);
    }
    if (!succeeded) {
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
    }
}

static void cmux_run_fallback_worker(
    CMUXSubmissionResult initial_result,
    const char *subcommand,
    const char *socket_path,
    const CMUXBuffer *request,
    const CMUXBuffer *payload
) {
    CMUXSubmissionResult result = initial_result;
    if (result == CMUX_SUBMISSION_RETRYABLE
        && socket_path != NULL
        && request->count > 0) {
        result = cmux_submit_request(
            socket_path,
            request,
            CMUX_HOOK_WORKER_RETRY_ATTEMPTS,
            CMUX_HOOK_WORKER_ATTEMPT_TIMEOUT_MILLISECONDS
        );
        if (result == CMUX_SUBMISSION_QUEUED) {
            return;
        }
    }
    cmux_run_cli_fallback(
        subcommand,
        socket_path,
        payload,
        result == CMUX_SUBMISSION_UNSUPPORTED,
        CMUX_HOOK_FALLBACK_TIMEOUT_MILLISECONDS
    );
}

static bool cmux_start_fallback_worker(
    CMUXSubmissionResult initial_result,
    const char *subcommand,
    const char *socket_path,
    const CMUXBuffer *request,
    const CMUXBuffer *payload
) {
    pid_t worker = -1;
#if defined(DEBUG)
    const char *force_fork_failure = getenv("CMUX_TEST_FORCE_HOOK_FORK_FAILURE");
    if (force_fork_failure == NULL || strcmp(force_fork_failure, "1") != 0) {
        worker = fork();
    } else {
        errno = EAGAIN;
    }
#else
    worker = fork();
#endif
    if (worker < 0) {
        return false;
    }
    if (worker == 0) {
        (void)setsid();
        cmux_close_inherited_worker_descriptors();
        cmux_run_fallback_worker(initial_result, subcommand, socket_path, request, payload);
        _exit(0);
    }
    int status = 0;
    (void)waitpid(worker, &status, WNOHANG);
    return true;
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
    const char *queue_protocol = getenv("CMUX_AGENT_HOOK_ENQUEUE_V1");
    const bool queue_protocol_advertised = queue_protocol != NULL
        && strcmp(queue_protocol, "1") == 0;
    // An older app never exports this capability. Skip the new socket method
    // entirely in that case so a global new helper cannot lose events while
    // talking to an older app/CLI during a rolling upgrade.
    CMUXSubmissionResult submission = queue_protocol_advertised
        ? CMUX_SUBMISSION_RETRYABLE
        : CMUX_SUBMISSION_UNSUPPORTED;
    CMUXBuffer request = {0};
    if (queue_protocol_advertised
        && payload_base64 != NULL
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
        submission = cmux_submit_request(
            socket_path,
            &request,
            1,
            CMUX_HOOK_FOREGROUND_TIMEOUT_MILLISECONDS
        );
    }

    const bool needs_fallback = submission != CMUX_SUBMISSION_QUEUED
        && submission != CMUX_SUBMISSION_HANDOFF_UNACKNOWLEDGED;
    if (needs_fallback) {
        // Emit and detach the caller-visible descriptors before forking. The
        // worker can then start whenever the scheduler permits without
        // extending Codex's hook latency or retaining its stdout pipe.
        cmux_print_noop();
        cmux_redirect_standard_descriptors_to_null();
        const bool started = cmux_start_fallback_worker(
            submission,
            subcommand,
            socket_path,
            &request,
            &payload
        );
        if (!started) {
            // Process pressure can make fork return EAGAIN. Preserve the old
            // delivery attempt under its own short deadline rather than
            // silently dropping the event or violating the hook budget.
            cmux_run_cli_fallback(
                subcommand,
                socket_path,
                &payload,
                submission == CMUX_SUBMISSION_UNSUPPORTED,
                CMUX_HOOK_EMERGENCY_FALLBACK_TIMEOUT_MILLISECONDS
            );
        }
    }

    cmux_buffer_destroy(&request);
    free(environment_base64);
    free(payload_base64);
    cmux_buffer_destroy(&environment);
    cmux_buffer_destroy(&payload);
    if (!needs_fallback) {
        cmux_print_noop();
    }
    return 0;
}
