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

// Keep the range layout available even when the prebuilt GhosttyKit module
// does not expose the fork-only declaration from ghostty.h. The setter bridge
// accepts an opaque pointer, so this prefixed mirror preserves the canonical
// six-byte ABI without introducing a duplicate public Ghostty symbol.
typedef struct {
    uint16_t row;
    uint16_t start_column;
    uint16_t end_column;
} cmux_external_hover_cell_range_s;

_Static_assert(sizeof(cmux_external_hover_cell_range_s) == 6,
               "ExternalHover cell range ABI size changed");
_Static_assert(offsetof(cmux_external_hover_cell_range_s, row) == 0,
               "ExternalHover cell range row offset changed");
_Static_assert(offsetof(cmux_external_hover_cell_range_s, start_column) == 2,
               "ExternalHover cell range start offset changed");
_Static_assert(offsetof(cmux_external_hover_cell_range_s, end_column) == 4,
               "ExternalHover cell range end offset changed");

// The prebuilt module can hide Ghostty's fork-only diagnostics declaration in
// the same way as the cell-range declaration above. Keep the POD mirror and
// bind the drain entry point explicitly to the canonical exported symbol.
typedef struct {
    uint64_t event;
    uint8_t source;
    uint8_t reason;
    uint8_t verdict;
    uint8_t flags;
    uint32_t seq;
} cmux_external_hover_diag_entry_s;

_Static_assert(sizeof(cmux_external_hover_diag_entry_s) == 16,
               "ExternalHover diagnostic ABI size changed");
_Static_assert(offsetof(cmux_external_hover_diag_entry_s, event) == 0,
               "ExternalHover diagnostic event offset changed");
_Static_assert(offsetof(cmux_external_hover_diag_entry_s, source) == 8,
               "ExternalHover diagnostic source offset changed");
_Static_assert(offsetof(cmux_external_hover_diag_entry_s, reason) == 9,
               "ExternalHover diagnostic reason offset changed");
_Static_assert(offsetof(cmux_external_hover_diag_entry_s, verdict) == 10,
               "ExternalHover diagnostic verdict offset changed");
_Static_assert(offsetof(cmux_external_hover_diag_entry_s, flags) == 11,
               "ExternalHover diagnostic flags offset changed");
_Static_assert(offsetof(cmux_external_hover_diag_entry_s, seq) == 12,
               "ExternalHover diagnostic sequence offset changed");

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

size_t cmux_ghostty_surface_drain_external_hover_diagnostics(
    ghostty_surface_t,
    cmux_external_hover_diag_entry_s* out_entries,
    size_t capacity,
    uint64_t* out_dropped_count_cumulative
) CMUX_GHOSTTY_EXTERNAL_HOVER_ASM(ghostty_surface_drain_external_hover_diagnostics);

#undef CMUX_GHOSTTY_EXTERNAL_HOVER_ASM

#endif
