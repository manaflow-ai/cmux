#include "include/GhosttyRuntimeTestStubs.h"

#if defined(__APPLE__)
#include <dlfcn.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <strings.h>

typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} GhosttyRuntimeTestColor;

typedef struct {
    GhosttyRuntimeTestColor foreground;
    bool has_foreground;
    uint32_t diagnostics_count;
} GhosttyRuntimeTestConfig;

#if defined(__APPLE__)
typedef int (*GhosttyInitFunction)(uintptr_t argc, char **argv);

// Newer Ghostty archives can be pulled into the test bundle by libc symbols
// before any Ghostty API is referenced. Initialize that real runtime before
// Swift Testing starts. Dynamic lookup avoids a link-time reference when
// SwiftPM leaves the archive unloaded and these stubs are the implementation.
__attribute__((constructor))
static void initialize_linked_ghostty_runtime(void) {
    GhosttyInitFunction ghostty_init =
        (GhosttyInitFunction)dlsym(RTLD_DEFAULT, "ghostty_init");
    if (ghostty_init == NULL) return;

    static char process_name[] = "CmuxTerminalCoreTests";
    static char *argv[] = {process_name, NULL};
    if (ghostty_init(1, argv) != 0) abort();
}
#endif

GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_surface_new_with_scrollback_limit(
    void *app,
    const void *config,
    size_t scrollback_limit_bytes
) {
    (void)app;
    (void)config;
    (void)scrollback_limit_bytes;
    return 0;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK bool ghostty_surface_clear_selection(void *surface) {
    (void)surface;
    return false;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK float ghostty_surface_font_size(void *surface) {
    (void)surface;
    return 0;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_surface_quicklook_font(void *surface) {
    (void)surface;
    return 0;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK void *ghostty_config_new(void) {
    return calloc(1, sizeof(GhosttyRuntimeTestConfig));
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK void ghostty_config_free(void *config) {
    free(config);
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK void ghostty_config_load_string(
    void *raw_config,
    const char *contents,
    uintptr_t contents_len,
    const char *path
) {
    (void)contents_len;
    (void)path;
    GhosttyRuntimeTestConfig *config = raw_config;
    const char *value = strchr(contents, '=');
    if (config == 0 || value == 0) return;
    do { value++; } while (*value == ' ' || *value == '\t');

    if (strcasecmp(value, "black") == 0) {
        config->foreground = (GhosttyRuntimeTestColor){0, 0, 0};
        config->has_foreground = true;
        return;
    }

    config->diagnostics_count = 1;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK bool ghostty_config_get(
    void *raw_config,
    void *raw_value,
    const char *key,
    uintptr_t key_len
) {
    GhosttyRuntimeTestConfig *config = raw_config;
    if (config == 0 || raw_value == 0 || !config->has_foreground ||
        key_len != strlen("foreground") || strncmp(key, "foreground", key_len) != 0) {
        return false;
    }
    *(GhosttyRuntimeTestColor *)raw_value = config->foreground;
    return true;
}

GHOSTTY_RUNTIME_TEST_STUB_WEAK uint32_t ghostty_config_diagnostics_count(void *raw_config) {
    GhosttyRuntimeTestConfig *config = raw_config;
    return config == 0 ? 0 : config->diagnostics_count;
}
