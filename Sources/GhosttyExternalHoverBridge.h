// The ExternalHover entry points are supplied by cmux's pinned Ghostty fork.
// Keep their declarations local to the Swift bridge instead of including
// ghostty/include/ghostty.h: that source tree also contains a GhosttyKit
// module map, which conflicts with the binary framework module map during
// Xcode's explicit module scan.
#ifndef CMUX_GHOSTTY_EXTERNAL_HOVER_BRIDGE_H
#define CMUX_GHOSTTY_EXTERNAL_HOVER_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// These two fork-only PODs are intentionally prefixed and kept local to the
// bridge. Some published GhosttyKit module caches contain the corresponding
// symbols but were generated from a header that did not export their
// declarations. The layouts are pinned by the fork's C API and are copied
// without depending on a module-provided typedef or union member.
typedef struct {
    uint64_t event;
    uint8_t source;
    uint8_t reason;
    uint8_t verdict;
    uint8_t flags;
    uint32_t seq;
} cmux_external_hover_diag_entry_s;

typedef struct {
    uint64_t token_bits[4];
    bool active;
} cmux_external_link_hover_action_s;

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

bool ghostty_surface_read_text_physical_rows(
    ghostty_surface_t,
    ghostty_selection_s,
    ghostty_text_s*);

// Use a prefixed C declaration with the original linker symbol. This avoids a
// duplicate declaration when a newer GhosttyKit header exports the native
// range typedef while still allowing older module caches to call the symbol.
bool cmux_ghostty_surface_set_external_link_hover(
    ghostty_surface_t,
    uint32_t top_row,
    uint32_t row_count,
    const char* text,
    size_t text_len,
    // The fork-only range typedef is not exported consistently by every
    // GhosttyKit module cache. It is a packed three-UInt16 POD, so its
    // pointer has the same ABI as void* and Swift passes the typed buffer
    // without a conversion at the call site.
    const void* ranges,
    size_t range_count,
    uint64_t out_token_bits[4],
    uint64_t host_event_id) __asm__("ghostty_surface_set_external_link_hover");

void ghostty_surface_clear_external_link_hover(
    ghostty_surface_t,
    const uint64_t token_bits[4]);

size_t cmux_ghostty_surface_drain_external_hover_diagnostics(
    ghostty_surface_t,
    cmux_external_hover_diag_entry_s* out_entries,
    size_t out_capacity,
    uint64_t* out_dropped_count_cumulative) __asm__("ghostty_surface_drain_external_hover_diagnostics");

#endif
