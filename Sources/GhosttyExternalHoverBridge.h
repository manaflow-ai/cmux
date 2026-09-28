// The binary GhosttyKit module contains the canonical ExternalHover symbols,
// but its explicit-module import does not consistently surface every
// fork-only declaration to the app bridging header. Keep these declarations
// prefixed and bind them to the canonical symbols so the bridge adds no
// duplicate C names or alternate ABI.
#ifndef CMUX_GHOSTTY_EXTERNAL_HOVER_BRIDGE_H
#define CMUX_GHOSTTY_EXTERNAL_HOVER_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint64_t token_bits[4];
    bool active;
} cmux_external_link_hover_action_s;

// Clang's asm labels name the object-file symbol verbatim. Darwin object
// files prefix C symbols with `_`, while the source-level spelling omits it.
// Include that prefix here so Swift's imported bridge references the symbols
// exported by GhosttyKit instead of asking ld for a distinct, unprefixed name.
#if defined(__APPLE__)
#define CMUX_GHOSTTY_EXTERNAL_HOVER_ASM(name) __asm__("_" #name)
#else
#define CMUX_GHOSTTY_EXTERNAL_HOVER_ASM(name) __asm__(#name)
#endif

static inline bool cmux_ghostty_action_is_external_link_hover(ghostty_action_s action) {
    // The fork appends this action after the stable selection-changed tag.
    return (int)action.tag == (int)GHOSTTY_ACTION_SELECTION_CHANGED + 1;
}

static inline cmux_external_link_hover_action_s cmux_ghostty_action_external_link_hover(
    ghostty_action_s action
) {
    cmux_external_link_hover_action_s result = {0};
    memcpy(&result, &action.action, sizeof(result));
    return result;
}

bool cmux_ghostty_surface_read_text_physical_rows(
    ghostty_surface_t,
    ghostty_selection_s,
    ghostty_text_s*) CMUX_GHOSTTY_EXTERNAL_HOVER_ASM(ghostty_surface_read_text_physical_rows);

bool cmux_ghostty_surface_set_external_link_hover(
    ghostty_surface_t,
    uint32_t top_row,
    uint32_t row_count,
    const char* text,
    size_t text_len,
    const void* ranges,
    size_t range_count,
    uint64_t out_token_bits[4],
    uint64_t host_event_id) CMUX_GHOSTTY_EXTERNAL_HOVER_ASM(ghostty_surface_set_external_link_hover);

void cmux_ghostty_surface_clear_external_link_hover(
    ghostty_surface_t,
    const uint64_t token_bits[4]) CMUX_GHOSTTY_EXTERNAL_HOVER_ASM(ghostty_surface_clear_external_link_hover);

#undef CMUX_GHOSTTY_EXTERNAL_HOVER_ASM

#endif
