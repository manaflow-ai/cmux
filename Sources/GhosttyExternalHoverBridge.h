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

#ifndef CMUX_GHOSTTY_SURFACE_TYPE_DECLARED
#define CMUX_GHOSTTY_SURFACE_TYPE_DECLARED
typedef void* ghostty_surface_t;
#endif

typedef enum {
  GHOSTTY_POINT_ACTIVE,
  GHOSTTY_POINT_VIEWPORT,
  GHOSTTY_POINT_SCREEN,
  GHOSTTY_POINT_SURFACE,
} ghostty_point_tag_e;

typedef enum {
  GHOSTTY_POINT_COORD_EXACT,
  GHOSTTY_POINT_COORD_TOP_LEFT,
  GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
} ghostty_point_coord_e;

typedef struct {
  ghostty_point_tag_e tag;
  ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;

typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} ghostty_text_s;

typedef struct {
  uint16_t row;
  uint16_t start_column;
  uint16_t end_column;
} ghostty_external_hover_cell_range_s;

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
    const ghostty_external_hover_cell_range_s* ranges,
    size_t range_count,
    uint64_t out_token_bits[4],
    uint64_t host_event_id);

void ghostty_surface_clear_external_link_hover(
    ghostty_surface_t,
    const uint64_t token_bits[4]);

#endif
