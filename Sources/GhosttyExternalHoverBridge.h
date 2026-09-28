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

bool ghostty_surface_read_text_physical_rows(
    ghostty_surface_t,
    ghostty_selection_s,
    ghostty_text_s*);

bool ghostty_surface_set_external_link_hover(
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
    uint64_t host_event_id);

void ghostty_surface_clear_external_link_hover(
    ghostty_surface_t,
    const uint64_t token_bits[4]);

#endif
