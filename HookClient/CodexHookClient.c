#include <ctype.h>
#include <CommonCrypto/CommonHMAC.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
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
#include <sys/file.h>
#include <sys/mman.h>
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
    CMUX_HOOK_OUTBOX_MAX_RECORDS = 1024,
    CMUX_HOOK_OUTBOX_MAX_BYTES = 256 * 1024 * 1024,
    CMUX_HOOK_FALLBACK_MAX_WORKERS = 32,
    CMUX_HOOK_OUTBOX_BUDGET_VERSION = 2,
    CMUX_HOOK_OUTBOX_GENERATION_BYTES = 16,
    CMUX_HOOK_OUTBOX_AUTHORITY_ACTIVE = 1,
    CMUX_HOOK_OUTBOX_AUTHORITY_REVOKED = 2,
    CMUX_HOOK_OUTBOX_RESERVATION_RESERVED = 1,
    CMUX_HOOK_OUTBOX_RESERVATION_PUBLISHED = 2,
    CMUX_HOOK_OUTBOX_LOCK_RETRY_COUNT = 250,
    CMUX_HOOK_OUTBOX_LOCK_RETRY_NANOSECONDS = 100 * 1000,
};

static const char cmux_hook_outbox_budget_name[] = ".quota-v1";
static const unsigned char cmux_hook_outbox_budget_magic[8] = {
    'C', 'M', 'U', 'X', 'H', 'Q', '0', '2',
};

typedef struct {
    unsigned char magic[8];
    uint32_t version;
    uint32_t slot_count;
    uint64_t maximum_bytes;
    uint32_t occupied_records;
    uint32_t next_slot;
    uint64_t occupied_bytes;
    unsigned char generation[CMUX_HOOK_OUTBOX_GENERATION_BYTES];
    uint32_t authority_state;
    uint32_t reserved;
} CMUXHookOutboxBudgetHeader;

typedef struct {
    uint64_t token;
    uint64_t reserved_bytes;
    uint64_t created_nanoseconds;
    int32_t owner_pid;
    uint32_t state;
} CMUXHookOutboxReservationRecord;

typedef struct {
    int descriptor;
    uint32_t slot_index;
    CMUXHookOutboxReservationRecord record;
    unsigned char generation[CMUX_HOOK_OUTBOX_GENERATION_BYTES];
    bool active;
} CMUXHookOutboxReservation;

_Static_assert(sizeof(CMUXHookOutboxBudgetHeader) == 64, "outbox budget header layout");
_Static_assert(sizeof(CMUXHookOutboxReservationRecord) == 32, "outbox reservation layout");

typedef enum {
    CMUX_SUBMISSION_RETRYABLE,
    CMUX_SUBMISSION_QUEUED,
    CMUX_SUBMISSION_UNSUPPORTED,
    CMUX_SUBMISSION_REJECTED,
} CMUXSubmissionResult;

typedef struct {
    unsigned char *bytes;
    size_t count;
    size_t capacity;
} CMUXBuffer;

typedef struct {
    const char *name;
    const char *pid_environment_key;
    const char *disable_environment_key;
    const char *delivery_id_prefix;
    const char *native_filename_prefix;
    const char *legacy_filename_prefix;
} CMUXHookAgent;

static const CMUXHookAgent cmux_hook_agents[] = {
    {
        .name = "codex",
        .pid_environment_key = "CMUX_CODEX_PID",
        .disable_environment_key = "CMUX_CODEX_HOOKS_DISABLED",
        .delivery_id_prefix = "codex",
        .native_filename_prefix = "cmux-codex-native-hook-",
        .legacy_filename_prefix = "cmux-codex-hook-",
    },
    {
        .name = "claude",
        .pid_environment_key = "CMUX_CLAUDE_PID",
        .disable_environment_key = "CMUX_CLAUDE_HOOKS_DISABLED",
        .delivery_id_prefix = "claude",
        .native_filename_prefix = "cmux-claude-native-hook-",
        .legacy_filename_prefix = "cmux-claude-hook-",
    },
};

static void cmux_secure_zero(void *bytes, size_t count) {
    volatile unsigned char *cursor = bytes;
    while (count > 0) {
        *cursor = 0;
        cursor += 1;
        count -= 1;
    }
}

// Keep this selected-key shape aligned with
// AgentHookTransportEnvironmentPolicy. The Swift decoder remains the authority
// for value normalization and durable/ephemeral credential partitioning.
static const char *const cmux_hook_environment_exact_keys[] = {
    "HOME",
    "PATH",
    "PWD",
    "TMPDIR",
    "TMP",
    "TEMP",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "CODEX_HOME",
    "CMUX_AGENT_HOOK_STATE_DIR",
    "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
    "CMUX_AGENT_LAUNCH_ARGV_B64",
    "CMUX_AGENT_LAUNCH_CWD",
    "CMUX_AGENT_LAUNCH_EXECUTABLE",
    "CMUX_AGENT_LAUNCH_KIND",
    "CMUX_AGENT_MANAGED_SUBAGENT",
    "CMUX_BUNDLE_ID",
    "CMUX_CLAUDE_PID",
    "CMUX_CODEX_PID",
    "CMUX_CUSTOM_CLAUDE_PATH",
    "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
    "CMUX_SURFACE_ID",
    "CMUX_TAG",
    "CMUX_WORKSPACE_ID",
    "CMUX_SOCKET_PATH",
    "ALL_PROXY",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "all_proxy",
    "https_proxy",
    "http_proxy",
    "no_proxy",
    "CURL_CA_BUNDLE",
    "REQUESTS_CA_BUNDLE",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "AMP_LOG_FILE",
    "AMP_LOG_LEVEL",
    "AMP_SETTINGS_FILE",
    "AMP_URL",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "CAMPFIRE_CODING_AGENT_DIR",
    "CAMPFIRE_CODING_AGENT_SESSION_DIR",
    "CAMPFIRE_RELAY_URL",
    "CLAUDE_CONFIG_DIR",
    "CMUX_ROVODEV_SESSIONS_DIR",
    "CODEBUDDY_BASE_URL",
    "CODEBUDDY_CONFIG_DIR",
    "CODEBUDDY_ENV_FILE",
    "CODEBUDDY_INTERNET_ENVIRONMENT",
    "CODEBUDDY_MODEL",
    "CODEBUDDY_SMALL_FAST_MODEL",
    "COPILOT_GH_HOST",
    "COPILOT_HOME",
    "COPILOT_MODEL",
    "COPILOT_OFFLINE",
    "COPILOT_PROVIDER_BASE_URL",
    "COPILOT_PROVIDER_MAX_OUTPUT_TOKENS",
    "COPILOT_PROVIDER_MAX_PROMPT_TOKENS",
    "COPILOT_PROVIDER_MODEL_ID",
    "COPILOT_PROVIDER_TYPE",
    "COPILOT_PROVIDER_WIRE_API",
    "COPILOT_PROVIDER_WIRE_MODEL",
    "CUSTOM_BASE_URL",
    "GEMINI_CLI_HOME",
    "GH_HOST",
    "GROK_HOME",
    "GROK_SANDBOX",
    "HERMES_CODEX_BASE_URL",
    "HERMES_HOME",
    "KIRO_HOME",
    "KIRO_LOG_LEVEL",
    "KIRO_LOG_NO_COLOR",
    "NODE_OPTIONS",
    "OPENCODE_CONFIG_DIR",
    "OLLAMA_EDITOR",
    "OLLAMA_HOST",
    "OLLAMA_NOHISTORY",
    "PI_CACHE_RETENTION",
    "PI_CONFIG_DIR",
    "PI_CODING_AGENT_DIR",
    "PI_CODING_AGENT_SESSION_DIR",
    "PI_OFFLINE",
    "PI_PACKAGE_DIR",
    "PI_SKIP_VERSION_CHECK",
    "QODER_CONFIG_DIR",
    "USE_BUILTIN_RIPGREP",
    NULL,
};

static const char *const cmux_hook_environment_prefixes[] = {
    "ANTHROPIC_",
    "AWS_",
    "CLOUD_ML_",
    "GCLOUD_",
    "GEMINI_",
    "GOOGLE_",
    "OPENAI_",
    "OPENROUTER_",
    "XAI_",
    NULL,
};

static const char *const cmux_hook_environment_suffixes[] = {
    "_ACCESS_TOKEN",
    "_API_KEY",
    "_AUTH_TOKEN",
    "_CLIENT_SECRET",
    "_API_URL",
    "_BASE_URL",
    "_MODEL",
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

static const CMUXHookAgent *cmux_hook_agent(
    const char *executable_path,
    const char **subcommand
) {
    const char *name = strrchr(executable_path, '/');
    name = name == NULL ? executable_path : name + 1;
    const CMUXHookAgent *agent = NULL;
    for (size_t index = 0;
         index < sizeof(cmux_hook_agents) / sizeof(cmux_hook_agents[0]);
         index += 1) {
        const CMUXHookAgent *candidate = &cmux_hook_agents[index];
        const size_t native_prefix_count = strlen(candidate->native_filename_prefix);
        const size_t legacy_prefix_count = strlen(candidate->legacy_filename_prefix);
        if (strncmp(name, candidate->native_filename_prefix, native_prefix_count) == 0) {
            name += native_prefix_count;
            agent = candidate;
            break;
        }
        if (strncmp(name, candidate->legacy_filename_prefix, legacy_prefix_count) == 0) {
            name += legacy_prefix_count;
            agent = candidate;
            break;
        }
    }
    if (agent == NULL) {
        return NULL;
    }

    static const struct CMUXHookDefinition {
        const char *filename_tag;
        const char *subcommand;
    } codex_hooks[] = {
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
    static const struct CMUXHookDefinition claude_hooks[] = {
        {"session-start", "session-start"},
        {"prompt-submit", "prompt-submit"},
        {"stop", "stop"},
        {"session-end", "session-end"},
        {"notification", "notification"},
        {"pre-tool-use", "pre-tool-use"},
        {"push-notification", "push-notification"},
        {"feed-SubagentStop", "feed:SubagentStop"},
        {NULL, NULL},
    };
    const struct CMUXHookDefinition *hooks = strcmp(agent->name, "claude") == 0
        ? claude_hooks
        : codex_hooks;
    for (size_t index = 0; hooks[index].filename_tag != NULL; index += 1) {
        const size_t length = strlen(hooks[index].filename_tag);
        if (strncmp(name, hooks[index].filename_tag, length) == 0
            && cmux_hook_filename_suffix_is_valid(name + length)) {
            *subcommand = hooks[index].subcommand;
            return agent;
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

static const char *cmux_resolve_agent_pid(
    const CMUXHookAgent *agent,
    char storage[32]
) {
    const char *pid = getenv(agent->pid_environment_key);
    if (cmux_pid_string_is_valid(pid)) {
        return pid;
    }
    snprintf(storage, 32, "%d", getppid());
    setenv(agent->pid_environment_key, storage, 1);
    return storage;
}

static const char *cmux_resolve_delivery_id(
    const CMUXHookAgent *agent,
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
        "%s-%s-%s-%d-%016llx",
        agent->delivery_id_prefix,
        agent_pid,
        subcommand,
        getpid(),
        (unsigned long long)nonce
    );
    setenv("CMUX_AGENT_HOOK_DELIVERY_ID", storage, 1);
    return storage;
}

static bool cmux_hook_environment_key_is_allowed(const char *key, size_t key_count) {
    for (size_t index = 0; cmux_hook_environment_exact_keys[index] != NULL; index += 1) {
        const char *allowed = cmux_hook_environment_exact_keys[index];
        if (strlen(allowed) == key_count && memcmp(key, allowed, key_count) == 0) {
            return true;
        }
    }
    for (size_t index = 0; cmux_hook_environment_prefixes[index] != NULL; index += 1) {
        const char *prefix = cmux_hook_environment_prefixes[index];
        const size_t prefix_count = strlen(prefix);
        if (key_count >= prefix_count && memcmp(key, prefix, prefix_count) == 0) {
            return true;
        }
    }
    for (size_t index = 0; cmux_hook_environment_suffixes[index] != NULL; index += 1) {
        const char *suffix = cmux_hook_environment_suffixes[index];
        const size_t suffix_count = strlen(suffix);
        if (key_count >= suffix_count
            && memcmp(key + key_count - suffix_count, suffix, suffix_count) == 0) {
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

static int cmux_lowercase_hex_digit(unsigned char byte) {
    if (byte >= '0' && byte <= '9') {
        return byte - '0';
    }
    if (byte >= 'a' && byte <= 'f') {
        return byte - 'a' + 10;
    }
    return -1;
}

static bool cmux_decode_outbox_generation(
    const char *encoded,
    unsigned char generation[CMUX_HOOK_OUTBOX_GENERATION_BYTES]
) {
    if (encoded == NULL
        || strlen(encoded) != CMUX_HOOK_OUTBOX_GENERATION_BYTES * 2) {
        return false;
    }
    bool any_nonzero = false;
    for (size_t index = 0; index < CMUX_HOOK_OUTBOX_GENERATION_BYTES; index += 1) {
        const int high = cmux_lowercase_hex_digit((unsigned char)encoded[index * 2]);
        const int low = cmux_lowercase_hex_digit((unsigned char)encoded[index * 2 + 1]);
        if (high < 0 || low < 0) {
            return false;
        }
        generation[index] = (unsigned char)((high << 4) | low);
        any_nonzero = any_nonzero || generation[index] != 0;
    }
    return any_nonzero;
}

static bool cmux_build_command(
    CMUXBuffer *command,
    const CMUXHookAgent *agent,
    const char *delivery_id,
    const char *subcommand,
    const char *payload_base64,
    const char *environment_base64
) {
    return cmux_buffer_append_string(command, "{\"id\":\"hook-")
        && cmux_buffer_append_string(command, delivery_id)
        && cmux_buffer_append_string(
            command,
            "\",\"method\":\"agent.hook.enqueue\",\"params\":{\"delivery_id\":\""
        )
        && cmux_buffer_append_string(command, delivery_id)
        && cmux_buffer_append_string(command, "\",\"agent\":\"")
        && cmux_buffer_append_string(command, agent->name)
        && cmux_buffer_append_string(command, "\",\"subcommand\":\"")
        && cmux_buffer_append_string(command, subcommand)
        && cmux_buffer_append_string(command, "\",\"payload_b64\":\"")
        && cmux_buffer_append_string(command, payload_base64)
        && cmux_buffer_append_string(command, "\",\"environment_b64\":\"")
        && cmux_buffer_append_string(command, environment_base64)
        && cmux_buffer_append_string(command, "\"}}\n");
}

static bool cmux_build_socket_request(
    CMUXBuffer *request,
    const CMUXBuffer *command,
    const char *capability
) {
    return cmux_buffer_append_string(request, "_cmux_capability_v1 ")
        && cmux_buffer_append_string(request, capability)
        && cmux_buffer_append_string(request, " ")
        && cmux_buffer_append(request, command->bytes, command->count);
}

static int cmux_base64url_digit(unsigned char byte) {
    if (byte >= 'A' && byte <= 'Z') {
        return byte - 'A';
    }
    if (byte >= 'a' && byte <= 'z') {
        return byte - 'a' + 26;
    }
    if (byte >= '0' && byte <= '9') {
        return byte - '0' + 52;
    }
    if (byte == '-') {
        return 62;
    }
    if (byte == '_') {
        return 63;
    }
    return -1;
}

static bool cmux_base64url_decode_exact(
    const char *input,
    size_t input_count,
    unsigned char *output,
    size_t output_count
) {
    uint32_t accumulator = 0;
    int available_bits = 0;
    size_t output_index = 0;
    for (size_t index = 0; index < input_count; index += 1) {
        const int digit = cmux_base64url_digit((unsigned char)input[index]);
        if (digit < 0) {
            return false;
        }
        accumulator = (accumulator << 6) | (uint32_t)digit;
        available_bits += 6;
        while (available_bits >= 8) {
            available_bits -= 8;
            if (output_index >= output_count) {
                return false;
            }
            output[output_index++] = (unsigned char)(accumulator >> available_bits);
            if (available_bits == 0) {
                accumulator = 0;
            } else {
                accumulator &= ((uint32_t)1 << available_bits) - 1;
            }
        }
    }
    return output_index == output_count && (available_bits == 0 || accumulator == 0);
}

static bool cmux_outbox_authentication(
    const char *capability,
    const CMUXBuffer *command,
    char nonce[65],
    unsigned char code[CC_SHA256_DIGEST_LENGTH]
) {
    static const char version[] = "v1.";
    if (capability == NULL || strncmp(capability, version, sizeof(version) - 1) != 0) {
        return false;
    }
    const char *nonce_start = capability + sizeof(version) - 1;
    const char *separator = strchr(nonce_start, '.');
    if (separator == NULL || strchr(separator + 1, '.') != NULL) {
        return false;
    }
    const size_t nonce_count = (size_t)(separator - nonce_start);
    const char *signature_start = separator + 1;
    const size_t signature_count = strlen(signature_start);
    if (nonce_count == 0 || nonce_count >= 65 || signature_count == 0) {
        return false;
    }
    unsigned char signature[CC_SHA256_DIGEST_LENGTH] = {0};
    if (!cmux_base64url_decode_exact(
            signature_start,
            signature_count,
            signature,
            sizeof(signature))) {
        return false;
    }
    memcpy(nonce, nonce_start, nonce_count);
    nonce[nonce_count] = '\0';

    static const unsigned char domain[] = "cmux.agent-hook-outbox.v1";
    CCHmacContext context;
    CCHmacInit(&context, kCCHmacAlgSHA256, signature, sizeof(signature));
    CCHmacUpdate(&context, domain, sizeof(domain));
    CCHmacUpdate(&context, command->bytes, command->count);
    CCHmacFinal(&context, code);
    cmux_secure_zero(signature, sizeof(signature));
    return true;
}

static bool cmux_pwrite_all(
    int descriptor,
    const unsigned char *bytes,
    size_t count
) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t written = pwrite(
            descriptor,
            bytes + offset,
            count - offset,
            (off_t)offset
        );
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

static bool cmux_store_shared_memory(
    int descriptor,
    const unsigned char *bytes,
    size_t count
) {
    if (count == 0 || ftruncate(descriptor, (off_t)count) != 0) {
        return false;
    }
    void *mapping = mmap(NULL, count, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    if (mapping == MAP_FAILED) {
        return false;
    }
    memcpy(mapping, bytes, count);
    munmap(mapping, count);
    return true;
}

static int cmux_open_private_outbox_directory(const char *path) {
    if (path == NULL || path[0] != '/') {
        return -1;
    }
    const int descriptor = open(
        path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (descriptor < 0) {
        return -1;
    }
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0
        || !S_ISDIR(status.st_mode)
        || status.st_uid != geteuid()
        || (status.st_mode & 0077) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static uint64_t cmux_monotonic_nanoseconds(void) {
    struct timespec time = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
        return 0;
    }
    return (uint64_t)time.tv_sec * 1000 * 1000 * 1000 + (uint64_t)time.tv_nsec;
}

static bool cmux_pread_all_at(
    int descriptor,
    void *bytes,
    size_t count,
    off_t offset
) {
    size_t completed = 0;
    while (completed < count) {
        const ssize_t amount = pread(
            descriptor,
            (unsigned char *)bytes + completed,
            count - completed,
            offset + (off_t)completed
        );
        if (amount > 0) {
            completed += (size_t)amount;
            continue;
        }
        if (amount < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

static bool cmux_pwrite_all_at(
    int descriptor,
    const void *bytes,
    size_t count,
    off_t offset
) {
    size_t completed = 0;
    while (completed < count) {
        const ssize_t amount = pwrite(
            descriptor,
            (const unsigned char *)bytes + completed,
            count - completed,
            offset + (off_t)completed
        );
        if (amount > 0) {
            completed += (size_t)amount;
            continue;
        }
        if (amount < 0 && errno == EINTR) {
            continue;
        }
        return false;
    }
    return true;
}

static bool cmux_flock(int descriptor, int operation) {
    if (operation != LOCK_EX) {
        for (int attempt = 0; attempt < 8; attempt += 1) {
            if (flock(descriptor, operation) == 0) {
                return true;
            }
            if (errno != EINTR) {
                return false;
            }
        }
        return false;
    }

    const uint64_t started = cmux_monotonic_nanoseconds();
    const uint64_t deadline = started == 0
        ? 0
        : started + (uint64_t)CMUX_HOOK_OUTBOX_LOCK_RETRY_COUNT
            * (uint64_t)CMUX_HOOK_OUTBOX_LOCK_RETRY_NANOSECONDS;
    // Hook admission is a foreground latency boundary. A stopped process may
    // retain this advisory lock indefinitely, so contention must fall through
    // after a strict deadline. The short retry window still lets ordinary
    // concurrent publishers serialize instead of needlessly abandoning the
    // durable outbox during a burst.
    for (int attempt = 0; attempt < CMUX_HOOK_OUTBOX_LOCK_RETRY_COUNT; attempt += 1) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) {
            return true;
        }
        if (errno != EINTR && errno != EWOULDBLOCK && errno != EAGAIN) {
            return false;
        }
        if (deadline != 0 && cmux_monotonic_nanoseconds() >= deadline) {
            return false;
        }
        const struct timespec pause = {
            .tv_sec = 0,
            .tv_nsec = CMUX_HOOK_OUTBOX_LOCK_RETRY_NANOSECONDS,
        };
        (void)nanosleep(&pause, NULL);
    }
    return false;
}

static uint64_t cmux_debug_limit(
    const char *environment_key,
    uint64_t default_value,
    uint64_t minimum,
    uint64_t maximum
) {
#if defined(DEBUG)
    const char *value = getenv(environment_key);
    if (value != NULL && value[0] != '\0') {
        char *end = NULL;
        errno = 0;
        const unsigned long long parsed = strtoull(value, &end, 10);
        if (errno == 0 && end != value && *end == '\0'
            && parsed >= minimum && parsed <= maximum) {
            return (uint64_t)parsed;
        }
    }
#else
    (void)environment_key;
    (void)minimum;
    (void)maximum;
#endif
    return default_value;
}

static bool cmux_process_exists(pid_t process_id) {
    if (process_id <= 1) {
        return false;
    }
    if (kill(process_id, 0) == 0) {
        return true;
    }
    return errno == EPERM;
}

typedef struct {
    uint64_t values[CMUX_HOOK_OUTBOX_MAX_RECORDS];
    size_t count;
} CMUXHookOutboxMarkerTokens;

static int cmux_compare_uint64(const void *left, const void *right) {
    const uint64_t lhs = *(const uint64_t *)left;
    const uint64_t rhs = *(const uint64_t *)right;
    return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
}

static bool cmux_collect_outbox_marker_tokens(
    int directory,
    CMUXHookOutboxMarkerTokens *tokens
) {
    tokens->count = 0;
    const int scan_descriptor = openat(
        directory,
        ".",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (scan_descriptor < 0) {
        return false;
    }
    DIR *entries = fdopendir(scan_descriptor);
    if (entries == NULL) {
        close(scan_descriptor);
        return false;
    }
    bool succeeded = true;
    struct dirent *entry = NULL;
    while ((entry = readdir(entries)) != NULL) {
        const char *name = entry->d_name;
        const bool prefix_matches = strncmp(name, "pending-", 8) == 0
            || strncmp(name, "ready-", 6) == 0;
        const size_t count = strlen(name);
        if (!prefix_matches || count < 16) {
            continue;
        }
        char token_text[17];
        memcpy(token_text, name + count - 16, 16);
        token_text[16] = '\0';
        char *end = NULL;
        errno = 0;
        const unsigned long long token = strtoull(token_text, &end, 16);
        if (errno != 0 || end == token_text || *end != '\0') {
            continue;
        }
        if (tokens->count >= CMUX_HOOK_OUTBOX_MAX_RECORDS) {
            succeeded = false;
            break;
        }
        tokens->values[tokens->count++] = (uint64_t)token;
    }
    closedir(entries);
    if (succeeded) {
        qsort(tokens->values, tokens->count, sizeof(tokens->values[0]), cmux_compare_uint64);
    }
    return succeeded;
}

static bool cmux_outbox_marker_tokens_contain(
    const CMUXHookOutboxMarkerTokens *tokens,
    uint64_t token
) {
    return bsearch(
        &token,
        tokens->values,
        tokens->count,
        sizeof(tokens->values[0]),
        cmux_compare_uint64
    ) != NULL;
}

static off_t cmux_outbox_reservation_offset(uint32_t slot_index) {
    return (off_t)sizeof(CMUXHookOutboxBudgetHeader)
        + (off_t)slot_index * (off_t)sizeof(CMUXHookOutboxReservationRecord);
}

static bool cmux_outbox_generation_is_valid(
    const unsigned char generation[CMUX_HOOK_OUTBOX_GENERATION_BYTES]
) {
    for (size_t index = 0; index < CMUX_HOOK_OUTBOX_GENERATION_BYTES; index += 1) {
        if (generation[index] != 0) {
            return true;
        }
    }
    return false;
}

static bool cmux_outbox_budget_header_is_valid(
    const CMUXHookOutboxBudgetHeader *header,
    off_t file_size
) {
    if (memcmp(header->magic, cmux_hook_outbox_budget_magic, sizeof(header->magic)) != 0
        || header->version != CMUX_HOOK_OUTBOX_BUDGET_VERSION
        || header->slot_count == 0
        || header->slot_count > CMUX_HOOK_OUTBOX_MAX_RECORDS
        || header->maximum_bytes == 0
        || header->maximum_bytes > CMUX_HOOK_OUTBOX_MAX_BYTES
        || header->occupied_records > header->slot_count
        || header->next_slot >= header->slot_count
        || header->occupied_bytes > header->maximum_bytes
        || !cmux_outbox_generation_is_valid(header->generation)
        || (header->authority_state != CMUX_HOOK_OUTBOX_AUTHORITY_ACTIVE
            && header->authority_state != CMUX_HOOK_OUTBOX_AUTHORITY_REVOKED)
        || header->reserved != 0) {
        return false;
    }
    const off_t expected_size = (off_t)sizeof(*header)
        + (off_t)header->slot_count * (off_t)sizeof(CMUXHookOutboxReservationRecord);
    return file_size == expected_size;
}

static bool cmux_read_outbox_budget(
    int descriptor,
    CMUXHookOutboxBudgetHeader *header
) {
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0
        || !S_ISREG(status.st_mode)
        || status.st_uid != geteuid()
        || (status.st_mode & 0077) != 0) {
        return false;
    }
    if (status.st_size < (off_t)sizeof(*header)
        || !cmux_pread_all_at(descriptor, header, sizeof(*header), 0)) {
        return false;
    }
    return cmux_outbox_budget_header_is_valid(header, status.st_size);
}

static int cmux_open_outbox_budget(int directory) {
    const int descriptor = openat(
        directory,
        cmux_hook_outbox_budget_name,
        O_RDWR | O_NOFOLLOW | O_CLOEXEC
    );
    if (descriptor < 0) {
        return -1;
    }
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0
        || !S_ISREG(status.st_mode)
        || status.st_uid != geteuid()
        || (status.st_mode & 0077) != 0) {
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static void cmux_unlink_outbox_shared_memory(uint64_t token) {
    char shared_memory_name[32];
    snprintf(
        shared_memory_name,
        sizeof(shared_memory_name),
        "/ch%016llx",
        (unsigned long long)token
    );
    shm_unlink(shared_memory_name);
}

static bool cmux_outbox_record_is_valid(
    const CMUXHookOutboxReservationRecord *record,
    const CMUXHookOutboxBudgetHeader *header
) {
    if (record->state == 0) {
        return record->token == 0
            && record->reserved_bytes == 0
            && record->created_nanoseconds == 0
            && record->owner_pid == 0;
    }
    return record->token != 0
        && record->reserved_bytes != 0
        && record->reserved_bytes <= header->maximum_bytes
        && (record->state == CMUX_HOOK_OUTBOX_RESERVATION_RESERVED
            || record->state == CMUX_HOOK_OUTBOX_RESERVATION_PUBLISHED);
}

static bool cmux_reconcile_outbox_budget_locked(
    int directory,
    int descriptor,
    CMUXHookOutboxBudgetHeader *header
) {
    const size_t records_size = (size_t)header->slot_count
        * sizeof(CMUXHookOutboxReservationRecord);
    CMUXHookOutboxReservationRecord *records = malloc(records_size);
    if (records == NULL || !cmux_pread_all_at(
            descriptor,
            records,
            records_size,
            (off_t)sizeof(*header))) {
        free(records);
        return false;
    }
    CMUXHookOutboxMarkerTokens marker_tokens = {0};
    if (!cmux_collect_outbox_marker_tokens(directory, &marker_tokens)) {
        free(records);
        return false;
    }

    uint32_t occupied_records = 0;
    uint64_t occupied_bytes = 0;
    uint32_t first_free = UINT32_MAX;
    for (uint32_t index = 0; index < header->slot_count; index += 1) {
        CMUXHookOutboxReservationRecord *record = &records[index];
        if (!cmux_outbox_record_is_valid(record, header)) {
            free(records);
            return false;
        }
        if (record->state == 0) {
            if (first_free == UINT32_MAX) {
                first_free = index;
            }
            continue;
        }
        if (!cmux_process_exists(record->owner_pid)
            && !cmux_outbox_marker_tokens_contain(&marker_tokens, record->token)) {
            cmux_unlink_outbox_shared_memory(record->token);
            memset(record, 0, sizeof(*record));
            if (!cmux_pwrite_all_at(
                    descriptor,
                    record,
                    sizeof(*record),
                    cmux_outbox_reservation_offset(index))) {
                free(records);
                return false;
            }
            if (first_free == UINT32_MAX) {
                first_free = index;
            }
            continue;
        }
        if (occupied_bytes > header->maximum_bytes - record->reserved_bytes) {
            free(records);
            return false;
        }
        occupied_bytes += record->reserved_bytes;
        occupied_records += 1;
    }
    header->occupied_records = occupied_records;
    header->occupied_bytes = occupied_bytes;
    header->next_slot = first_free == UINT32_MAX ? 0 : first_free;
    const bool succeeded = cmux_pwrite_all_at(
        descriptor,
        header,
        sizeof(*header),
        0
    );
    free(records);
    return succeeded;
}

static bool cmux_reserve_outbox_budget(
    int directory,
    const unsigned char generation[CMUX_HOOK_OUTBOX_GENERATION_BYTES],
    uint64_t token,
    size_t message_bytes,
    CMUXHookOutboxReservation *reservation
) {
    memset(reservation, 0, sizeof(*reservation));
    reservation->descriptor = -1;
    if (!cmux_outbox_generation_is_valid(generation)
        || token == 0
        || message_bytes == 0) {
        return false;
    }
    const int page_size = getpagesize();
    if (page_size <= 0 || message_bytes > SIZE_MAX - ((size_t)page_size - 1)) {
        return false;
    }
    const uint64_t rounded_bytes = (uint64_t)(
        ((message_bytes + (size_t)page_size - 1) / (size_t)page_size) * (size_t)page_size
    );
    const int descriptor = cmux_open_outbox_budget(directory);
    if (descriptor < 0 || !cmux_flock(descriptor, LOCK_EX)) {
        if (descriptor >= 0) {
            close(descriptor);
        }
        return false;
    }

    bool succeeded = false;
    CMUXHookOutboxBudgetHeader header = {0};
    if (!cmux_read_outbox_budget(descriptor, &header)) {
        goto done;
    }
    if (header.authority_state != CMUX_HOOK_OUTBOX_AUTHORITY_ACTIVE
        || memcmp(header.generation, generation, sizeof(header.generation)) != 0
        || rounded_bytes > header.maximum_bytes) {
        goto done;
    }
    if (header.occupied_records >= header.slot_count
        || header.occupied_bytes > header.maximum_bytes - rounded_bytes) {
        if (!cmux_reconcile_outbox_budget_locked(directory, descriptor, &header)
            || header.occupied_records >= header.slot_count
            || header.occupied_bytes > header.maximum_bytes - rounded_bytes) {
            goto done;
        }
    }

    uint32_t available_slot = UINT32_MAX;
    for (uint32_t offset = 0; offset < header.slot_count; offset += 1) {
        const uint32_t index = (header.next_slot + offset) % header.slot_count;
        CMUXHookOutboxReservationRecord candidate = {0};
        if (!cmux_pread_all_at(
                descriptor,
                &candidate,
                sizeof(candidate),
                cmux_outbox_reservation_offset(index))
            || !cmux_outbox_record_is_valid(&candidate, &header)) {
            goto done;
        }
        if (candidate.state == 0) {
            available_slot = index;
            break;
        }
    }
    if (available_slot == UINT32_MAX) {
        if (!cmux_reconcile_outbox_budget_locked(directory, descriptor, &header)) {
            goto done;
        }
        for (uint32_t offset = 0; offset < header.slot_count; offset += 1) {
            const uint32_t index = (header.next_slot + offset) % header.slot_count;
            CMUXHookOutboxReservationRecord candidate = {0};
            if (!cmux_pread_all_at(
                    descriptor,
                    &candidate,
                    sizeof(candidate),
                    cmux_outbox_reservation_offset(index))
                || !cmux_outbox_record_is_valid(&candidate, &header)) {
                goto done;
            }
            if (candidate.state == 0) {
                available_slot = index;
                break;
            }
        }
        if (available_slot == UINT32_MAX) {
            goto done;
        }
    }

    CMUXHookOutboxReservationRecord record = {
        .token = token,
        .reserved_bytes = rounded_bytes,
        .created_nanoseconds = cmux_monotonic_nanoseconds(),
        .owner_pid = getpid(),
        .state = CMUX_HOOK_OUTBOX_RESERVATION_RESERVED,
    };
    header.occupied_records += 1;
    header.occupied_bytes += rounded_bytes;
    header.next_slot = (available_slot + 1) % header.slot_count;
    // Increment first: a process crash can conservatively leak capacity, but
    // can never leave an unaccounted shared-memory allocation. App startup and
    // the saturated slow path recompute leaked counters from fixed slots.
    if (!cmux_pwrite_all_at(descriptor, &header, sizeof(header), 0)
        || !cmux_pwrite_all_at(
            descriptor,
            &record,
            sizeof(record),
            cmux_outbox_reservation_offset(available_slot))) {
        goto done;
    }
    reservation->descriptor = descriptor;
    reservation->slot_index = available_slot;
    reservation->record = record;
    memcpy(reservation->generation, generation, sizeof(reservation->generation));
    reservation->active = true;
    succeeded = true;

done:
    (void)cmux_flock(descriptor, LOCK_UN);
    if (!succeeded) {
        close(descriptor);
    }
    return succeeded;
}

static void cmux_release_outbox_reservation(CMUXHookOutboxReservation *reservation) {
    if (reservation == NULL || !reservation->active || reservation->descriptor < 0) {
        return;
    }
    if (cmux_flock(reservation->descriptor, LOCK_EX)) {
        CMUXHookOutboxReservationRecord stored = {0};
        if (cmux_pread_all_at(
                reservation->descriptor,
                &stored,
                sizeof(stored),
                cmux_outbox_reservation_offset(reservation->slot_index))
            && stored.token == reservation->record.token) {
            CMUXHookOutboxReservationRecord empty = {0};
            CMUXHookOutboxBudgetHeader header = {0};
            if (cmux_read_outbox_budget(reservation->descriptor, &header)
                && memcmp(
                    header.generation,
                    reservation->generation,
                    sizeof(header.generation)
                ) == 0
                && header.occupied_records > 0
                && header.occupied_bytes >= stored.reserved_bytes
                && cmux_pwrite_all_at(
                reservation->descriptor,
                &empty,
                sizeof(empty),
                cmux_outbox_reservation_offset(reservation->slot_index))) {
                header.occupied_records -= 1;
                header.occupied_bytes -= stored.reserved_bytes;
                header.next_slot = reservation->slot_index;
                (void)cmux_pwrite_all_at(
                    reservation->descriptor,
                    &header,
                    sizeof(header),
                    0
                );
            }
        }
        (void)cmux_flock(reservation->descriptor, LOCK_UN);
    }
    close(reservation->descriptor);
    reservation->descriptor = -1;
    reservation->active = false;
}

static bool cmux_commit_outbox_reservation(
    CMUXHookOutboxReservation *reservation,
    int directory,
    const char *pending_name,
    const char *ready_name
) {
    if (reservation == NULL
        || !reservation->active
        || reservation->descriptor < 0
        || pending_name == NULL
        || ready_name == NULL
        || !cmux_flock(reservation->descriptor, LOCK_EX)) {
        return false;
    }

    bool committed = false;
    CMUXHookOutboxBudgetHeader header = {0};
    CMUXHookOutboxReservationRecord stored = {0};
    if (cmux_read_outbox_budget(reservation->descriptor, &header)
        && header.authority_state == CMUX_HOOK_OUTBOX_AUTHORITY_ACTIVE
        && memcmp(
            header.generation,
            reservation->generation,
            sizeof(header.generation)
        ) == 0
        && cmux_pread_all_at(
            reservation->descriptor,
            &stored,
            sizeof(stored),
            cmux_outbox_reservation_offset(reservation->slot_index))
        && stored.token == reservation->record.token
        && stored.state == CMUX_HOOK_OUTBOX_RESERVATION_RESERVED
        && renameat(directory, pending_name, directory, ready_name) == 0) {
        stored.state = CMUX_HOOK_OUTBOX_RESERVATION_PUBLISHED;
        // The ready rename is the durable publication point. If this diagnostic
        // state write fails, reconciliation still retains the marker-backed slot.
        (void)cmux_pwrite_all_at(
            reservation->descriptor,
            &stored,
            sizeof(stored),
            cmux_outbox_reservation_offset(reservation->slot_index)
        );
        committed = true;
    }
    (void)cmux_flock(reservation->descriptor, LOCK_UN);
    if (committed) {
        close(reservation->descriptor);
        reservation->descriptor = -1;
        reservation->active = false;
    }
    return committed;
}

#if defined(DEBUG)
static bool cmux_debug_stop_after_outbox_reserve(uint64_t token) {
    const char *path = getenv("CMUX_TEST_HOOK_OUTBOX_STOP_AFTER_RESERVE_FILE");
    if (path == NULL || path[0] == '\0') {
        return true;
    }
    char signal[64];
    const int signal_count = snprintf(
        signal,
        sizeof(signal),
        "reserved %016llx\n",
        (unsigned long long)token
    );
    if (path[0] != '/'
        || signal_count <= 0
        || (size_t)signal_count >= sizeof(signal)) {
        return false;
    }
    const int descriptor = open(
        path,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        0600
    );
    if (descriptor < 0) {
        return false;
    }
    const bool signaled = fchmod(descriptor, 0600) == 0
        && cmux_pwrite_all(
            descriptor,
            (const unsigned char *)signal,
            (size_t)signal_count
        )
        && fsync(descriptor) == 0;
    close(descriptor);
    if (!signaled) {
        return false;
    }
    return raise(SIGSTOP) == 0;
}
#endif

static bool cmux_publish_outbox(
    const char *directory_path,
    const char *capability,
    const char *encoded_generation,
    const CMUXBuffer *command
) {
    unsigned char generation[CMUX_HOOK_OUTBOX_GENERATION_BYTES] = {0};
    char nonce[65] = {0};
    unsigned char code[CC_SHA256_DIGEST_LENGTH] = {0};
    if (!cmux_decode_outbox_generation(encoded_generation, generation)
        || !cmux_outbox_authentication(capability, command, nonce, code)) {
        return false;
    }
    char *encoded_code = cmux_base64_encode(code, sizeof(code));
    cmux_secure_zero(code, sizeof(code));
    if (encoded_code == NULL) {
        return false;
    }

    const int directory = cmux_open_private_outbox_directory(directory_path);
    if (directory < 0) {
        free(encoded_code);
        return false;
    }

    bool published = false;
    for (int attempt = 0; attempt < 8 && !published; attempt += 1) {
        uint64_t random = 0;
        arc4random_buf(&random, sizeof(random));
        if (random == 0) {
            continue;
        }
        CMUXHookOutboxReservation reservation = { .descriptor = -1 };
        if (!cmux_reserve_outbox_budget(
                directory,
                generation,
                random,
                command->count,
                &reservation)) {
            break;
        }
#if defined(DEBUG)
        const char *crash_after_reserve = getenv("CMUX_TEST_HOOK_OUTBOX_CRASH_AFTER_RESERVE");
        if (crash_after_reserve != NULL && strcmp(crash_after_reserve, "1") == 0) {
            _exit(86);
        }
        if (!cmux_debug_stop_after_outbox_reserve(random)) {
            cmux_release_outbox_reservation(&reservation);
            break;
        }
#endif
        const uint64_t timestamp = cmux_monotonic_nanoseconds();
        char shared_memory_name[32];
        char pending_name[96];
        char ready_name[96];
        snprintf(
            shared_memory_name,
            sizeof(shared_memory_name),
            "/ch%016llx",
            (unsigned long long)random
        );
        snprintf(
            pending_name,
            sizeof(pending_name),
            "pending-%016llx-%016llx",
            (unsigned long long)timestamp,
            (unsigned long long)random
        );
        snprintf(
            ready_name,
            sizeof(ready_name),
            "ready-%016llx-%016llx",
            (unsigned long long)timestamp,
            (unsigned long long)random
        );

        char marker[512];
        const int marker_count = snprintf(
            marker,
            sizeof(marker),
            "%s\n%s\n%s\n%zu\n%016llx\n%s\n",
            shared_memory_name,
            nonce,
            encoded_code,
            command->count,
            (unsigned long long)random,
            encoded_generation
        );
        if (marker_count <= 0 || (size_t)marker_count >= sizeof(marker)) {
            shm_unlink(shared_memory_name);
            cmux_release_outbox_reservation(&reservation);
            continue;
        }
        const int marker_descriptor = openat(
            directory,
            pending_name,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
            0600
        );
        if (marker_descriptor < 0) {
            cmux_release_outbox_reservation(&reservation);
            continue;
        }
        bool record_ready = fchmod(marker_descriptor, 0600) == 0
            && cmux_pwrite_all(
                marker_descriptor,
                (const unsigned char *)marker,
                (size_t)marker_count
        );
        close(marker_descriptor);
        if (!record_ready) {
            unlinkat(directory, pending_name, 0);
            cmux_release_outbox_reservation(&reservation);
            continue;
        }

        // Publish the discoverable pending manifest before allocating shared
        // memory. A helper killed at any later point leaves a name the app can
        // either recover after the grace period or clean without leaking an
        // unreachable kernel object.
        const int shared_memory = shm_open(
            shared_memory_name,
            O_CREAT | O_EXCL | O_RDWR,
            0600
        );
        if (shared_memory < 0) {
            unlinkat(directory, pending_name, 0);
            cmux_release_outbox_reservation(&reservation);
            continue;
        }
        struct stat shared_memory_status = {0};
        record_ready = fcntl(shared_memory, F_SETFD, FD_CLOEXEC) == 0
            && fstat(shared_memory, &shared_memory_status) == 0
            && shared_memory_status.st_uid == geteuid()
            && (shared_memory_status.st_mode & 0077) == 0
            && cmux_store_shared_memory(shared_memory, command->bytes, command->count);
        close(shared_memory);
        if (!record_ready
            || !cmux_commit_outbox_reservation(
                &reservation,
                directory,
                pending_name,
                ready_name
            )) {
            unlinkat(directory, pending_name, 0);
            shm_unlink(shared_memory_name);
            cmux_release_outbox_reservation(&reservation);
            continue;
        }
        published = true;
    }

    close(directory);
    free(encoded_code);
    return published;
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
            // Socket bytes are not durable acceptance. The normal advertised
            // path has already published to the bounded outbox; if that path
            // was unavailable, retry rather than losing an app-crash race.
            return CMUX_SUBMISSION_RETRYABLE;
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

static void cmux_wait_until(int64_t deadline) {
    for (;;) {
        const int64_t now = cmux_monotonic_milliseconds();
        if (now >= deadline) {
            return;
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

static bool cmux_fallback_group_has_descendants(pid_t group_leader) {
    pid_t members[256] = {0};
    const int member_count = proc_listpgrppids(group_leader, members, sizeof(members));
    const size_t capacity = sizeof(members) / sizeof(members[0]);
    if (member_count < 0 || (size_t)member_count >= capacity) {
        return true;
    }
    for (size_t index = 0; index < (size_t)member_count; index += 1) {
        if (members[index] > 0 && members[index] != group_leader) {
            return true;
        }
    }
    return false;
}

static bool cmux_reap_fallback_group_when_drained(pid_t child, int64_t deadline) {
    for (;;) {
        siginfo_t information = {0};
        if (waitid(P_PID, (id_t)child, &information, WEXITED | WNOHANG | WNOWAIT) == 0
            && information.si_pid == child
            && !cmux_fallback_group_has_descendants(child)) {
            int status = 0;
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            return true;
        }
        const int64_t now = cmux_monotonic_milliseconds();
        if (now >= deadline) {
            return false;
        }
        cmux_wait_until(now + 5);
    }
}

static void cmux_cleanup_fallback_process_group(pid_t child) {
    // Keep the leader unreaped until group cleanup. Its reserved PID is the
    // group sentinel, so this PGID cannot be reused while the permit-owning
    // supervisor is still responsible for double-forked descendants.
    (void)kill(-child, SIGTERM);
    cmux_wait_until(
        cmux_monotonic_milliseconds() + CMUX_HOOK_TERMINATION_GRACE_MILLISECONDS
    );
    (void)kill(-child, SIGKILL);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}

static void cmux_run_cli_fallback(
    const CMUXHookAgent *agent,
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
        (char *)agent->name,
        "enqueue",
        (char *)subcommand,
        NULL,
    };
    char *arguments_without_socket[] = {
        (char *)cli,
        "hooks",
        (char *)agent->name,
        "enqueue",
        (char *)subcommand,
        NULL,
    };
    char *legacy_arguments_with_socket[] = {
        (char *)cli,
        "--socket",
        (char *)socket_path,
        "hooks",
        (char *)agent->name,
        (char *)subcommand,
        NULL,
    };
    char *legacy_arguments_without_socket[] = {
        (char *)cli,
        "hooks",
        (char *)agent->name,
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
        (char *)agent->name,
        "--event",
        (char *)(subcommand + 5),
        NULL,
    };
    char *legacy_feed_arguments_without_socket[] = {
        (char *)cli,
        "hooks",
        "feed",
        "--source",
        (char *)agent->name,
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
    (void)cmux_write_all_fd_until(
        input_pipe[1],
        payload->bytes,
        payload->count,
        deadline
    );
    close(input_pipe[1]);
    if (!cmux_reap_fallback_group_when_drained(child, deadline)) {
        cmux_cleanup_fallback_process_group(child);
    }
}

static int cmux_open_fallback_worker_directory(void) {
    char path[PATH_MAX];
    const int count = snprintf(
        path,
        sizeof(path),
        "/private/tmp/cmux-agent-hook-workers-%u",
        (unsigned int)geteuid()
    );
    if (count <= 0 || (size_t)count >= sizeof(path)) {
        return -1;
    }
    if (mkdir(path, 0700) != 0 && errno != EEXIST) {
        return -1;
    }
    const int directory = open(
        path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (directory < 0) {
        return -1;
    }
    struct stat status = {0};
    if (fstat(directory, &status) != 0
        || !S_ISDIR(status.st_mode)
        || status.st_uid != geteuid()
        || (status.st_mode & 0077) != 0
        || fchmod(directory, 0700) != 0) {
        close(directory);
        return -1;
    }
    return directory;
}

static int cmux_acquire_fallback_worker_permit(void) {
    const int directory = cmux_open_fallback_worker_directory();
    if (directory < 0) {
        return -1;
    }
    const uint64_t maximum_workers = cmux_debug_limit(
        "CMUX_TEST_HOOK_FALLBACK_MAX_WORKERS",
        CMUX_HOOK_FALLBACK_MAX_WORKERS,
        1,
        CMUX_HOOK_FALLBACK_MAX_WORKERS
    );
    int permit = -1;
    for (uint64_t index = 0; index < maximum_workers; index += 1) {
        char name[48];
        snprintf(name, sizeof(name), ".worker-%02llu.lock", (unsigned long long)index);
        const int descriptor = openat(
            directory,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0600
        );
        if (descriptor < 0) {
            continue;
        }
        struct stat status = {0};
        if (fchmod(descriptor, 0600) != 0
            || fstat(descriptor, &status) != 0
            || !S_ISREG(status.st_mode)
            || status.st_uid != geteuid()
            || (status.st_mode & 0077) != 0) {
            close(descriptor);
            continue;
        }
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) {
            permit = descriptor;
            break;
        }
        close(descriptor);
    }
    close(directory);
    return permit;
}

static int cmux_fallback_timeout_milliseconds(void) {
    return (int)cmux_debug_limit(
        "CMUX_TEST_HOOK_FALLBACK_TIMEOUT_MILLISECONDS",
        CMUX_HOOK_FALLBACK_TIMEOUT_MILLISECONDS,
        50,
        10 * 1000
    );
}

static void cmux_close_inherited_worker_descriptors(int preserved_descriptor) {
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
                || raw_descriptor == directory_fd
                || raw_descriptor == preserved_descriptor) {
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
        if (descriptor != preserved_descriptor) {
            close(descriptor);
        }
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
    const CMUXHookAgent *agent,
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
        agent,
        subcommand,
        socket_path,
        payload,
        result == CMUX_SUBMISSION_UNSUPPORTED,
        cmux_fallback_timeout_milliseconds()
    );
}

static bool cmux_start_fallback_worker(
    CMUXSubmissionResult initial_result,
    const CMUXHookAgent *agent,
    const char *subcommand,
    const char *socket_path,
    const CMUXBuffer *request,
    const CMUXBuffer *payload,
    int *permit_descriptor
) {
    if (permit_descriptor == NULL || *permit_descriptor < 0) {
        return false;
    }
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
        const int permit = *permit_descriptor;
        cmux_close_inherited_worker_descriptors(permit);
        cmux_run_fallback_worker(
            initial_result,
            agent,
            subcommand,
            socket_path,
            request,
            payload
        );
        close(permit);
        _exit(0);
    }
    close(*permit_descriptor);
    *permit_descriptor = -1;
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

    const char *subcommand = NULL;
    const CMUXHookAgent *agent = cmux_hook_agent(arguments[0], &subcommand);
    if (agent == NULL || subcommand == NULL) {
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
    const char *disabled = getenv(agent->disable_environment_key);
    if (surface_id == NULL || surface_id[0] == '\0' || (disabled != NULL && strcmp(disabled, "1") == 0)) {
        cmux_buffer_destroy(&payload);
        cmux_print_noop();
        return 0;
    }

    char agent_pid_storage[32] = {0};
    const char *agent_pid = cmux_resolve_agent_pid(agent, agent_pid_storage);
    char delivery_id_storage[320] = {0};
    const char *delivery_id = cmux_resolve_delivery_id(
        agent,
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
    const char *outbox_capability = getenv("CMUX_AGENT_HOOK_OUTBOX_CAPABILITY");
    const char *outbox_generation = getenv("CMUX_AGENT_HOOK_OUTBOX_GENERATION");
    const char *queue_protocol = getenv("CMUX_AGENT_HOOK_ENQUEUE_V1");
    const char *outbox_directory = getenv("CMUX_AGENT_HOOK_OUTBOX_DIR");
    const bool queue_protocol_advertised = queue_protocol != NULL
        && strcmp(queue_protocol, "1") == 0;
    // An older app never exports this capability. Skip the new socket method
    // entirely in that case so a global new helper cannot lose events while
    // talking to an older app/CLI during a rolling upgrade.
    CMUXSubmissionResult submission = queue_protocol_advertised
        ? CMUX_SUBMISSION_RETRYABLE
        : CMUX_SUBMISSION_UNSUPPORTED;
    CMUXBuffer command = {0};
    CMUXBuffer request = {0};
    const bool command_built = payload_base64 != NULL
        && environment_base64 != NULL
        && cmux_build_command(
            &command,
            agent,
            delivery_id,
            subcommand,
            payload_base64,
            environment_base64
        );
    if (queue_protocol_advertised
        && command_built
        && cmux_capability_is_valid(outbox_capability)
        && outbox_directory != NULL
        && outbox_directory[0] != '\0'
        && cmux_publish_outbox(
            outbox_directory,
            outbox_capability,
            outbox_generation,
            &command
        )) {
        submission = CMUX_SUBMISSION_QUEUED;
    } else if (queue_protocol_advertised
        && command_built
        && socket_path != NULL
        && cmux_capability_is_valid(capability)
        && cmux_build_socket_request(&request, &command, capability)) {
        submission = cmux_submit_request(
            socket_path,
            &request,
            1,
            CMUX_HOOK_FOREGROUND_TIMEOUT_MILLISECONDS
        );
    }

    const bool needs_fallback = submission != CMUX_SUBMISSION_QUEUED;
    if (needs_fallback) {
        // Emit and detach the caller-visible descriptors before forking. The
        // worker can then start whenever the scheduler permits without
        // extending Codex's hook latency or retaining its stdout pipe.
        cmux_print_noop();
        cmux_redirect_standard_descriptors_to_null();
        int fallback_permit = cmux_acquire_fallback_worker_permit();
        const bool started = fallback_permit >= 0
            && cmux_start_fallback_worker(
                submission,
                agent,
                subcommand,
                socket_path,
                &request,
                &payload,
                &fallback_permit
            );
        if (!started && fallback_permit >= 0) {
            // Process pressure can make fork return EAGAIN. Preserve the old
            // delivery attempt under its own short deadline rather than
            // silently dropping the event or violating the hook budget.
            cmux_run_cli_fallback(
                agent,
                subcommand,
                socket_path,
                &payload,
                submission == CMUX_SUBMISSION_UNSUPPORTED,
                CMUX_HOOK_EMERGENCY_FALLBACK_TIMEOUT_MILLISECONDS
            );
            close(fallback_permit);
        }
    }

    cmux_buffer_destroy(&request);
    cmux_buffer_destroy(&command);
    free(environment_base64);
    free(payload_base64);
    cmux_buffer_destroy(&environment);
    cmux_buffer_destroy(&payload);
    if (!needs_fallback) {
        cmux_print_noop();
    }
    return 0;
}
