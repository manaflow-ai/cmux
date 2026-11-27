/* C ABI of the screen viewer core (cmux-rd-core `screen_kit::ffi`, feature
   `c-abi`), shared by the Mac app (linked through cmux-rd-ffi in the app
   library, CCmuxAppFFI) and the iOS app (through cmux-mobile-link-ffi in
   cmux-next-ios/rust, which depends on cmux-rd-ffi). CmuxScreenKit imports it
   as the header-only CCmuxScreenKit target; the app resolves the symbols at
   link. cmux-rd-core's header test checks it against the exports. No I/O, no threads;
   panics are caught and poison only the handle they hit. Strings are UTF-8
   pointer and length; nothing keeps a caller's pointer. A handle is used by
   one thread at a time. */
#ifndef CMUX_SCREEN_KIT_H
#define CMUX_SCREEN_KIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMUX_SCREEN_OK (0)
#define CMUX_SCREEN_ERR_NULL (-1)
#define CMUX_SCREEN_ERR_INVALID (-2)
#define CMUX_SCREEN_ERR_PANIC (-3)
/* The buffer is too small; the length needed was written. */
#define CMUX_SCREEN_ERR_BUFFER (-4)

#define CMUX_SCREEN_TRACKPAD_MOVE (0u)
#define CMUX_SCREEN_TRACKPAD_PRESS (1u)
#define CMUX_SCREEN_TRACKPAD_RELEASE (2u)
#define CMUX_SCREEN_TRACKPAD_MAX_ACTIONS (3)

typedef struct CmuxScreenPoint { double x; double y; } CmuxScreenPoint;
typedef struct CmuxScreenSize { double width; double height; } CmuxScreenSize;
typedef struct CmuxScreenRect { double x; double y; double width; double height; } CmuxScreenRect;
typedef struct CmuxScreenInsets { double top; double left; double bottom; double right; } CmuxScreenInsets;
typedef struct CmuxScreenFraming { double zoom_scale; CmuxScreenPoint content_offset; } CmuxScreenFraming;
/* Scroll remainder carried between strokes; start zeroed. */
typedef struct CmuxScreenScrollQuantizer { CmuxScreenPoint remainder; } CmuxScreenScrollQuantizer;
typedef struct CmuxScreenAcceleration {
    double minimum_gain;
    double maximum_gain;
    double slow_speed;   /* points per second */
    double fast_speed;
} CmuxScreenAcceleration;
/* A cursor shape: size and hotspot as fractions of the frame, points its size on screen. */
typedef struct CmuxScreenCursorGeometry {
    CmuxScreenSize size;
    CmuxScreenPoint hotspot;
    CmuxScreenSize points;
} CmuxScreenCursorGeometry;
typedef struct CmuxScreenCursorPlacement { CmuxScreenRect rect; double pixels_per_point; } CmuxScreenCursorPlacement;
typedef struct CmuxScreenHintPose { double x; double y; double scale; double ripple; double opacity; } CmuxScreenHintPose;
typedef struct CmuxScreenTrackpadAction {
    uint32_t kind;       /* CMUX_SCREEN_TRACKPAD_* */
    double dx;           /* move only: points */
    double dy;
    double dt;           /* move only: seconds */
} CmuxScreenTrackpadAction;

typedef struct CmuxScreenTrackpad CmuxScreenTrackpad;
typedef struct CmuxScreenClickSnap CmuxScreenClickSnap;
typedef struct CmuxScreenCursorCache CmuxScreenCursorCache;

/* Trackpad gesture: tap clicks, a second tap within the window drags, a long
   press holds. Each call writes up to CMUX_SCREEN_TRACKPAD_MAX_ACTIONS actions
   to out and their count to out_count. Times in seconds. */
CmuxScreenTrackpad *cmux_screen_trackpad_new(void);
void cmux_screen_trackpad_free(CmuxScreenTrackpad *trackpad);
int32_t cmux_screen_trackpad_touch_down(CmuxScreenTrackpad *trackpad, double time, CmuxScreenTrackpadAction *out, size_t *out_count);
int32_t cmux_screen_trackpad_touch_moved(CmuxScreenTrackpad *trackpad, double dx, double dy, double time, CmuxScreenTrackpadAction *out, size_t *out_count);
int32_t cmux_screen_trackpad_touch_up(CmuxScreenTrackpad *trackpad, double time, CmuxScreenTrackpadAction *out, size_t *out_count);
int32_t cmux_screen_trackpad_cancel(CmuxScreenTrackpad *trackpad, CmuxScreenTrackpadAction *out, size_t *out_count);
int32_t cmux_screen_trackpad_advance(CmuxScreenTrackpad *trackpad, double time, CmuxScreenTrackpadAction *out, size_t *out_count);
/* Whether the button is down, and when advance is due next (if at all). */
int32_t cmux_screen_trackpad_state(CmuxScreenTrackpad *trackpad, bool *out_held, bool *out_has_deadline, double *out_deadline);
/* Negative or non-finite values: CMUX_SCREEN_ERR_INVALID. */
int32_t cmux_screen_trackpad_set_timings(CmuxScreenTrackpad *trackpad, double tap_duration, double slop, double long_press_duration, double drag_window);

CmuxScreenAcceleration cmux_screen_acceleration_default(void);
double cmux_screen_acceleration_gain(CmuxScreenAcceleration acceleration, double speed);
CmuxScreenPoint cmux_screen_acceleration_delta(CmuxScreenAcceleration acceleration, double dx, double dy, double dt, double pixels_per_point);

/* A second tap near the first within the interval clicks the same point. */
CmuxScreenClickSnap *cmux_screen_click_snap_new(void);
void cmux_screen_click_snap_free(CmuxScreenClickSnap *snap);
int32_t cmux_screen_click_snap_point(CmuxScreenClickSnap *snap, CmuxScreenPoint point, double time, double radius, CmuxScreenPoint *out);

/* Framing and viewport math (points). */
CmuxScreenFraming cmux_screen_framing(CmuxScreenRect crop, CmuxScreenRect display, CmuxScreenSize view);
CmuxScreenRect cmux_screen_framing_visible(CmuxScreenFraming framing, CmuxScreenRect display, CmuxScreenSize view);
double cmux_screen_fit_scale(CmuxScreenRect rect, CmuxScreenSize view);
CmuxScreenPoint cmux_screen_centered_offset(CmuxScreenRect rect, double scale, CmuxScreenSize view);
double cmux_screen_maximum_zoom(double fit);
bool cmux_screen_same_zoom(double a, double b);
CmuxScreenPoint cmux_screen_clamped_offset(CmuxScreenPoint offset, CmuxScreenRect focus, double scale, CmuxScreenSize view, bool allow_horizontal);
size_t cmux_screen_page_target(size_t page, size_t count, double velocity_x, double moved, double view_width);
size_t cmux_screen_initial_page(const CmuxScreenRect *screens, size_t count);
CmuxScreenInsets cmux_screen_content_insets(bool centres_any, CmuxScreenSize view, CmuxScreenSize content);
int32_t cmux_screen_scroll_quantize(CmuxScreenScrollQuantizer *quantizer, CmuxScreenPoint translation, bool pixels, double pixels_per_point, int64_t *out_x, int64_t *out_y);
double cmux_screen_pixels_per_point(double zoom);
CmuxScreenPoint cmux_screen_clamp_to_rect(CmuxScreenPoint point, CmuxScreenRect rect);
CmuxScreenPoint cmux_screen_follow_cursor(CmuxScreenPoint offset, CmuxScreenPoint cursor, CmuxScreenSize view);
CmuxScreenPoint cmux_screen_clamp_to_content(CmuxScreenPoint offset, CmuxScreenInsets insets, CmuxScreenSize content, CmuxScreenSize view);
CmuxScreenSize cmux_screen_stream_layout_size(CmuxScreenSize video, bool has_display, CmuxScreenSize display);
int64_t cmux_screen_demand_long_edge(CmuxScreenSize frame, double zoom, double display_scale);
CmuxScreenPoint cmux_screen_normalized(CmuxScreenPoint point, CmuxScreenSize frame);
CmuxScreenPoint cmux_screen_clamp_to_frame(CmuxScreenPoint point, CmuxScreenSize frame);

/* Cursor shapes: an LRU of ids and geometry (the caller keeps the images and
   drops the one evicted). A short id buffer: CMUX_SCREEN_ERR_BUFFER with the
   length written. */
CmuxScreenCursorPlacement cmux_screen_cursor_placement(CmuxScreenCursorGeometry geometry, CmuxScreenPoint pointer, CmuxScreenSize frame);
CmuxScreenCursorCache *cmux_screen_cursor_cache_new(void);
void cmux_screen_cursor_cache_free(CmuxScreenCursorCache *cache);
int32_t cmux_screen_cursor_cache_add(CmuxScreenCursorCache *cache, const uint8_t *id, size_t id_len, CmuxScreenCursorGeometry geometry, bool *out_current, uint8_t *evicted, size_t evicted_cap, size_t *out_evicted_len);
/* id NULL: the host sends no shape names, nothing changes. */
int32_t cmux_screen_cursor_cache_select(CmuxScreenCursorCache *cache, const uint8_t *id, size_t id_len, bool *out_changed);
int32_t cmux_screen_cursor_cache_current(CmuxScreenCursorCache *cache, bool *out_has, uint8_t *out_id, size_t id_cap, size_t *out_id_len, CmuxScreenCursorGeometry *out_geometry);
int32_t cmux_screen_cursor_cache_reset(CmuxScreenCursorCache *cache);

/* Session policy. phase: 0 idle, 1 connecting, 2 connected, 3 failed, 4 ended. */
bool cmux_screen_reconnect_gives_up(int64_t attempts, int64_t limit, double elapsed);
double cmux_screen_reconnect_attempt_timeout(double elapsed);
double cmux_screen_reconnect_backoff_delay(int64_t attempt);
double cmux_screen_reconnect_deadline(void);
double cmux_screen_notice_delay(void);
bool cmux_screen_connecting_notice_shown(uint32_t phase, bool reconnecting, bool reconnect_notice_due, bool connect_notice_due);
bool cmux_screen_keeps_live_layout(uint32_t phase, bool reconnecting);
int32_t cmux_screen_encoding_name(int32_t encoding, uint8_t *out, size_t cap, size_t *out_len);

/* The trackpad hint's pose; animated false: the still hand. */
CmuxScreenHintPose cmux_screen_hint_pose(bool animated, double progress);

#ifdef __cplusplus
}
#endif

#endif /* CMUX_SCREEN_KIT_H */
