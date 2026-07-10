// Copyright (c) 2013 Marshall A. Greenblatt. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the name Chromium Embedded
// Framework nor the names of its contributors may be used to endorse
// or promote products derived from this software without specific prior
// written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#ifndef CEF_INCLUDE_INTERNAL_CEF_TYPES_WRAPPERS_H_
#define CEF_INCLUDE_INTERNAL_CEF_TYPES_WRAPPERS_H_
#pragma once

#include <algorithm>
#include <limits>

#include "include/internal/cef_string.h"
#include "include/internal/cef_string_list.h"
#include "include/internal/cef_types.h"

///
/// Template class that provides common functionality for complex CEF structure
/// wrapping. Use only with non-POD types that begin with a `size_t size` member
/// and can benefit from referencing unowned members.
///
template <class traits>
class CefStructBase : public traits::struct_type {
 public:
  using struct_type = typename traits::struct_type;

  CefStructBase() { Init(); }
  ~CefStructBase() {
    // Only clear this object's data if it isn't currently attached to a
    // structure.
    if (!attached_to_) {
      Clear(this);
    }
  }

  CefStructBase(const CefStructBase& r) {
    Init();
    *this = r;
  }
  CefStructBase(const struct_type& r) {
    Init();
    *this = r;
  }

  ///
  /// Attach to the source structure's existing values. DetachTo() can be called
  /// to insert the values back into the existing structure.
  ///
  void AttachTo(struct_type& source) {
    // Only clear this object's data if it isn't currently attached to a
    // structure.
    if (!attached_to_) {
      Clear(this);
    }

    // This object is now attached to the new structure.
    attached_to_ = &source;

    // Source structure may be smaller size.
    const size_t source_size = std::min(source.size, sizeof(struct_type));

    // Reference values from the source structure, and keep the same size.
    memcpy(static_cast<struct_type*>(this), &source, source_size);
    this->size = source_size;
  }

  ///
  /// Relinquish ownership of values to the target structure.
  ///
  void DetachTo(struct_type& target) {
    if (attached_to_ != &target) {
      // Clear the target structure's values only if we are not currently
      // attached to that structure.
      Clear(&target);
    }

    // Target structure may be smaller size.
    const size_t target_size = std::min(target.size, sizeof(struct_type));

    // Transfer ownership of the values to the target structure.
    memcpy(&target, static_cast<struct_type*>(this), target_size);

    if (target_size < sizeof(struct_type)) {
      // Zero the transferred portion and clear the remainder.
      memset(static_cast<struct_type*>(this), 0, target_size);
      this->size = sizeof(struct_type);
      Clear(this);
    }

    // Zero everything. We return to the default size.
    Init();
  }

  ///
  /// Set this object's values. If |copy| is true the source structure's values
  /// will be copied instead of referenced.
  ///
  void Set(const struct_type& source, bool copy) {
    if (source.size < sizeof(struct_type)) {
      // Clear newer members that won't be set.
      Clear(this);
    }
    traits::set(&source, this, copy);
  }

  CefStructBase& operator=(const CefStructBase& s) {
    return operator=(static_cast<const struct_type&>(s));
  }

  CefStructBase& operator=(const struct_type& s) {
    Set(s, true);
    return *this;
  }

 protected:
  void Init() {
    memset(static_cast<struct_type*>(this), 0, sizeof(struct_type));
    attached_to_ = NULL;
    traits::init(this);
  }

  static void Clear(struct_type* s) { traits::clear(s); }

  struct_type* attached_to_ = nullptr;
};

///
/// Template class that provides common functionality for simple CEF structure
/// wrapping. Use only with POD types that begin with a `size_t size` member.
///
template <class struct_type>
class CefStructBaseSimple : public struct_type {
 public:
  CefStructBaseSimple() : struct_type{sizeof(struct_type)} {}
  CefStructBaseSimple(const struct_type& r) { *this = r; }

  CefStructBaseSimple& operator=(const struct_type& r) {
    memcpy(static_cast<struct_type*>(this), &r,
           std::min(r.size, sizeof(struct_type)));
    this->size = sizeof(struct_type);
    return *this;
  }
};

///
/// Class representing a point.
///
class CefPoint : public cef_point_t {
 public:
  CefPoint() : cef_point_t{} {}
  CefPoint(const cef_point_t& r) : cef_point_t(r) {}
  CefPoint(int x, int y) : cef_point_t{x, y} {}

  bool IsEmpty() const { return x <= 0 && y <= 0; }
  void Set(int x_val, int y_val) { x = x_val, y = y_val; }
};

inline bool operator==(const CefPoint& a, const CefPoint& b) {
  return a.x == b.x && a.y == b.y;
}

inline bool operator!=(const CefPoint& a, const CefPoint& b) {
  return !(a == b);
}

///
/// Class representing a rectangle.
///
class CefRect : public cef_rect_t {
 public:
  CefRect() : cef_rect_t{} {}
  CefRect(const cef_rect_t& r) : cef_rect_t(r) {}
  CefRect(int x, int y, int width, int height)
      : cef_rect_t{x, y, width, height} {}

  bool IsEmpty() const { return width <= 0 || height <= 0; }
  void Set(int x_val, int y_val, int width_val, int height_val) {
    x = x_val, y = y_val, width = width_val, height = height_val;
  }

  ///
  /// Returns true if the point identified by point_x and point_y falls inside
  /// this rectangle.  The point (x, y) is inside the rectangle, but the
  /// point (x + width, y + height) is not.
  ///
  bool Contains(int point_x, int point_y) const {
    return (point_x >= x) && (point_x < x + width) && (point_y >= y) &&
           (point_y < y + height);
  }
  bool Contains(const CefPoint& point) const {
    return Contains(point.x, point.y);
  }
};

inline bool operator==(const CefRect& a, const CefRect& b) {
  return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}

inline bool operator!=(const CefRect& a, const CefRect& b) {
  return !(a == b);
}

///
/// Class representing a size.
///
class CefSize : public cef_size_t {
 public:
  CefSize() : cef_size_t{} {}
  CefSize(const cef_size_t& r) : cef_size_t(r) {}
  CefSize(int width, int height) : cef_size_t{width, height} {}

  bool IsEmpty() const { return width <= 0 || height <= 0; }
  void Set(int width_val, int height_val) {
    width = width_val, height = height_val;
  }
};

inline bool operator==(const CefSize& a, const CefSize& b) {
  return a.width == b.width && a.height == b.height;
}

inline bool operator!=(const CefSize& a, const CefSize& b) {
  return !(a == b);
}

///
/// Class representing a range.
///
class CefRange : public cef_range_t {
 public:
  CefRange() : cef_range_t{} {}
  CefRange(const cef_range_t& r) : cef_range_t(r) {}
  CefRange(uint32_t from, uint32_t to) : cef_range_t{from, to} {}

  static CefRange InvalidRange() {
    return CefRange((std::numeric_limits<uint32_t>::max)(),
                    (std::numeric_limits<uint32_t>::max)());
  }

  void Set(int from_val, int to_val) { from = from_val, to = to_val; }
};

inline bool operator==(const CefRange& a, const CefRange& b) {
  return a.from == b.from && a.to == b.to;
}

inline bool operator!=(const CefRange& a, const CefRange& b) {
  return !(a == b);
}

///
/// Class representing insets.
///
class CefInsets : public cef_insets_t {
 public:
  CefInsets() : cef_insets_t{} {}
  CefInsets(const cef_insets_t& r) : cef_insets_t(r) {}
  CefInsets(int top, int left, int bottom, int right)
      : cef_insets_t{top, left, bottom, right} {}

  void Set(int top_val, int left_val, int bottom_val, int right_val) {
    top = top_val, left = left_val, bottom = bottom_val, right = right_val;
  }
};

inline bool operator==(const CefInsets& a, const CefInsets& b) {
  return a.top == b.top && a.left == b.left && a.bottom == b.bottom &&
         a.right == b.right;
}

inline bool operator!=(const CefInsets& a, const CefInsets& b) {
  return !(a == b);
}

///
/// Class representing a draggable region.
///
class CefDraggableRegion : public cef_draggable_region_t {
 public:
  CefDraggableRegion() : cef_draggable_region_t{} {}
  CefDraggableRegion(const cef_draggable_region_t& r)
      : cef_draggable_region_t(r) {}
  CefDraggableRegion(const cef_rect_t& bounds, bool draggable)
      : cef_draggable_region_t{bounds, draggable} {}

  void Set(const CefRect& bounds_val, bool draggable_val) {
    bounds = bounds_val, draggable = draggable_val;
  }
};

inline bool operator==(const CefDraggableRegion& a,
                       const CefDraggableRegion& b) {
  return a.bounds == b.bounds && a.draggable == b.draggable;
}

inline bool operator!=(const CefDraggableRegion& a,
                       const CefDraggableRegion& b) {
  return !(a == b);
}

///
/// Class representing the virtual screen information for use when window
/// rendering is disabled.
///
class CefScreenInfo : public CefStructBaseSimple<cef_screen_info_t> {
 public:
  using base_type = CefStructBaseSimple<cef_screen_info_t>;
  using base_type::CefStructBaseSimple;
  using base_type::operator=;

  CefScreenInfo(float device_scale_factor,
                int depth,
                int depth_per_component,
                bool is_monochrome,
                const cef_rect_t& rect,
                const cef_rect_t& available_rect) {
    Set(device_scale_factor, depth, depth_per_component, is_monochrome, rect,
        available_rect);
  }

  void Set(float device_scale_factor_val,
           int depth_val,
           int depth_per_component_val,
           bool is_monochrome_val,
           const CefRect& rect_val,
           const CefRect& available_rect_val) {
    device_scale_factor = device_scale_factor_val;
    depth = depth_val;
    depth_per_component = depth_per_component_val;
    is_monochrome = is_monochrome_val;
    rect = rect_val;
    available_rect = available_rect_val;
  }
};

///
/// Class representing a a keyboard event.
///
using CefKeyEvent = CefStructBaseSimple<cef_key_event_t>;

///
/// Class representing a mouse event.
///
class CefMouseEvent : public cef_mouse_event_t {
 public:
  CefMouseEvent() : cef_mouse_event_t{} {}
  CefMouseEvent(const cef_mouse_event_t& r) : cef_mouse_event_t(r) {}
};

///
/// Class representing a touch event.
///
class CefTouchEvent : public cef_touch_event_t {
 public:
  CefTouchEvent() : cef_touch_event_t{} {}
  CefTouchEvent(const cef_touch_event_t& r) : cef_touch_event_t(r) {}
};

///
/// Class representing popup window features.
///
using CefPopupFeatures = CefStructBaseSimple<cef_popup_features_t>;

struct CefSettingsTraits {
  using struct_type = cef_settings_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->browser_subprocess_path);
    cef_string_clear(&s->framework_dir_path);
    cef_string_clear(&s->main_bundle_path);
    cef_string_clear(&s->cache_path);
    cef_string_clear(&s->root_cache_path);
    cef_string_clear(&s->user_agent);
    cef_string_clear(&s->user_agent_product);
    cef_string_clear(&s->locale);
    cef_string_clear(&s->log_file);
    cef_string_clear(&s->javascript_flags);
    cef_string_clear(&s->resources_dir_path);
    cef_string_clear(&s->locales_dir_path);
    cef_string_clear(&s->accept_language_list);
    cef_string_clear(&s->cookieable_schemes_list);
    cef_string_clear(&s->chrome_policy_id);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    target->no_sandbox = src->no_sandbox;
    cef_string_set(src->browser_subprocess_path.str,
                   src->browser_subprocess_path.length,
                   &target->browser_subprocess_path, copy);
    cef_string_set(src->framework_dir_path.str, src->framework_dir_path.length,
                   &target->framework_dir_path, copy);
    cef_string_set(src->main_bundle_path.str, src->main_bundle_path.length,
                   &target->main_bundle_path, copy);
    target->multi_threaded_message_loop = src->multi_threaded_message_loop;
    target->external_message_pump = src->external_message_pump;
    target->windowless_rendering_enabled = src->windowless_rendering_enabled;
    target->command_line_args_disabled = src->command_line_args_disabled;

    cef_string_set(src->cache_path.str, src->cache_path.length,
                   &target->cache_path, copy);
    cef_string_set(src->root_cache_path.str, src->root_cache_path.length,
                   &target->root_cache_path, copy);
    target->persist_session_cookies = src->persist_session_cookies;

    cef_string_set(src->user_agent.str, src->user_agent.length,
                   &target->user_agent, copy);
    cef_string_set(src->user_agent_product.str, src->user_agent_product.length,
                   &target->user_agent_product, copy);
    cef_string_set(src->locale.str, src->locale.length, &target->locale, copy);

    cef_string_set(src->log_file.str, src->log_file.length, &target->log_file,
                   copy);
    target->log_severity = src->log_severity;
    target->log_items = src->log_items;
    cef_string_set(src->javascript_flags.str, src->javascript_flags.length,
                   &target->javascript_flags, copy);

    cef_string_set(src->resources_dir_path.str, src->resources_dir_path.length,
                   &target->resources_dir_path, copy);
    cef_string_set(src->locales_dir_path.str, src->locales_dir_path.length,
                   &target->locales_dir_path, copy);
    target->remote_debugging_port = src->remote_debugging_port;
    target->uncaught_exception_stack_size = src->uncaught_exception_stack_size;
    target->background_color = src->background_color;

    cef_string_set(src->accept_language_list.str,
                   src->accept_language_list.length,
                   &target->accept_language_list, copy);

    cef_string_set(src->cookieable_schemes_list.str,
                   src->cookieable_schemes_list.length,
                   &target->cookieable_schemes_list, copy);
    target->cookieable_schemes_exclude_defaults =
        src->cookieable_schemes_exclude_defaults;

    cef_string_set(src->chrome_policy_id.str, src->chrome_policy_id.length,
                   &target->chrome_policy_id, copy);
    target->chrome_app_icon_id = src->chrome_app_icon_id;

#if defined(OS_POSIX) && !defined(OS_ANDROID)
    target->disable_signal_handlers = src->disable_signal_handlers;
#endif

#if CEF_API_ADDED(14600)
    target->use_views_default_popup = src->use_views_default_popup;
#endif
  }
};

///
/// Class representing initialization settings.
///
using CefSettings = CefStructBase<CefSettingsTraits>;

struct CefRequestContextSettingsTraits {
  using struct_type = cef_request_context_settings_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->cache_path);
    cef_string_clear(&s->accept_language_list);
    cef_string_clear(&s->cookieable_schemes_list);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    cef_string_set(src->cache_path.str, src->cache_path.length,
                   &target->cache_path, copy);
    target->persist_session_cookies = src->persist_session_cookies;
    cef_string_set(src->accept_language_list.str,
                   src->accept_language_list.length,
                   &target->accept_language_list, copy);

    cef_string_set(src->cookieable_schemes_list.str,
                   src->cookieable_schemes_list.length,
                   &target->cookieable_schemes_list, copy);
    target->cookieable_schemes_exclude_defaults =
        src->cookieable_schemes_exclude_defaults;
  }
};

///
/// Class representing request context initialization settings.
///
using CefRequestContextSettings =
    CefStructBase<CefRequestContextSettingsTraits>;

struct CefBrowserSettingsTraits {
  using struct_type = cef_browser_settings_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->standard_font_family);
    cef_string_clear(&s->fixed_font_family);
    cef_string_clear(&s->serif_font_family);
    cef_string_clear(&s->sans_serif_font_family);
    cef_string_clear(&s->cursive_font_family);
    cef_string_clear(&s->fantasy_font_family);
    cef_string_clear(&s->default_encoding);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    target->windowless_frame_rate = src->windowless_frame_rate;

    cef_string_set(src->standard_font_family.str,
                   src->standard_font_family.length,
                   &target->standard_font_family, copy);
    cef_string_set(src->fixed_font_family.str, src->fixed_font_family.length,
                   &target->fixed_font_family, copy);
    cef_string_set(src->serif_font_family.str, src->serif_font_family.length,
                   &target->serif_font_family, copy);
    cef_string_set(src->sans_serif_font_family.str,
                   src->sans_serif_font_family.length,
                   &target->sans_serif_font_family, copy);
    cef_string_set(src->cursive_font_family.str,
                   src->cursive_font_family.length,
                   &target->cursive_font_family, copy);
    cef_string_set(src->fantasy_font_family.str,
                   src->fantasy_font_family.length,
                   &target->fantasy_font_family, copy);

    target->default_font_size = src->default_font_size;
    target->default_fixed_font_size = src->default_fixed_font_size;
    target->minimum_font_size = src->minimum_font_size;
    target->minimum_logical_font_size = src->minimum_logical_font_size;

    cef_string_set(src->default_encoding.str, src->default_encoding.length,
                   &target->default_encoding, copy);

    target->remote_fonts = src->remote_fonts;
    target->javascript = src->javascript;
    target->javascript_close_windows = src->javascript_close_windows;
    target->javascript_access_clipboard = src->javascript_access_clipboard;
    target->javascript_dom_paste = src->javascript_dom_paste;
    target->image_loading = src->image_loading;
    target->image_shrink_standalone_to_fit =
        src->image_shrink_standalone_to_fit;
    target->text_area_resize = src->text_area_resize;
    target->tab_to_links = src->tab_to_links;
    target->local_storage = src->local_storage;
#if !CEF_API_ADDED(13800)
    target->databases = src->databases;
#endif
    target->webgl = src->webgl;

    target->background_color = src->background_color;

    target->chrome_status_bubble = src->chrome_status_bubble;
    target->chrome_zoom_bubble = src->chrome_zoom_bubble;
  }
};

///
/// Class representing browser initialization settings.
///
using CefBrowserSettings = CefStructBase<CefBrowserSettingsTraits>;

struct CefURLPartsTraits {
  using struct_type = cef_urlparts_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->spec);
    cef_string_clear(&s->scheme);
    cef_string_clear(&s->username);
    cef_string_clear(&s->password);
    cef_string_clear(&s->host);
    cef_string_clear(&s->port);
    cef_string_clear(&s->origin);
    cef_string_clear(&s->path);
    cef_string_clear(&s->query);
    cef_string_clear(&s->fragment);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    cef_string_set(src->spec.str, src->spec.length, &target->spec, copy);
    cef_string_set(src->scheme.str, src->scheme.length, &target->scheme, copy);
    cef_string_set(src->username.str, src->username.length, &target->username,
                   copy);
    cef_string_set(src->password.str, src->password.length, &target->password,
                   copy);
    cef_string_set(src->host.str, src->host.length, &target->host, copy);
    cef_string_set(src->port.str, src->port.length, &target->port, copy);
    cef_string_set(src->origin.str, src->origin.length, &target->origin, copy);
    cef_string_set(src->path.str, src->path.length, &target->path, copy);
    cef_string_set(src->query.str, src->query.length, &target->query, copy);
    cef_string_set(src->fragment.str, src->fragment.length, &target->fragment,
                   copy);
  }
};

///
/// Class representing a URL's component parts.
///
using CefURLParts = CefStructBase<CefURLPartsTraits>;

///
/// Class representing the state of a touch handle.
///
using CefTouchHandleState = CefStructBaseSimple<cef_touch_handle_state_t>;

struct CefCookieTraits {
  using struct_type = cef_cookie_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->name);
    cef_string_clear(&s->value);
    cef_string_clear(&s->domain);
    cef_string_clear(&s->path);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    cef_string_set(src->name.str, src->name.length, &target->name, copy);
    cef_string_set(src->value.str, src->value.length, &target->value, copy);
    cef_string_set(src->domain.str, src->domain.length, &target->domain, copy);
    cef_string_set(src->path.str, src->path.length, &target->path, copy);
    target->secure = src->secure;
    target->httponly = src->httponly;
    target->creation = src->creation;
    target->last_access = src->last_access;
    target->has_expires = src->has_expires;
    target->expires = src->expires;
    target->same_site = src->same_site;
    target->priority = src->priority;
  }
};

///
/// Class representing a cookie.
///
using CefCookie = CefStructBase<CefCookieTraits>;

///
/// Class representing cursor information.
///
class CefCursorInfo : public cef_cursor_info_t {
 public:
  CefCursorInfo() : cef_cursor_info_t{} {}
  CefCursorInfo(const cef_cursor_info_t& r) : cef_cursor_info_t(r) {}
};

struct CefPdfPrintSettingsTraits {
  using struct_type = cef_pdf_print_settings_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->page_ranges);
    cef_string_clear(&s->header_template);
    cef_string_clear(&s->footer_template);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    target->landscape = src->landscape;
    target->print_background = src->print_background;
    target->scale = src->scale;
    target->paper_width = src->paper_width;
    target->paper_height = src->paper_height;
    target->prefer_css_page_size = src->prefer_css_page_size;

    target->margin_type = src->margin_type;
    target->margin_top = src->margin_top;
    target->margin_right = src->margin_right;
    target->margin_bottom = src->margin_bottom;
    target->margin_left = src->margin_left;

    cef_string_set(src->page_ranges.str, src->page_ranges.length,
                   &target->page_ranges, copy);

    target->display_header_footer = src->display_header_footer;
    cef_string_set(src->header_template.str, src->header_template.length,
                   &target->header_template, copy);
    cef_string_set(src->footer_template.str, src->footer_template.length,
                   &target->footer_template, copy);

    target->generate_tagged_pdf = src->generate_tagged_pdf;
    target->generate_document_outline = src->generate_document_outline;
  }
};

///
/// Class representing PDF print settings
///
using CefPdfPrintSettings = CefStructBase<CefPdfPrintSettingsTraits>;

///
/// Class representing CefBoxLayout settings.
///
class CefBoxLayoutSettings
    : public CefStructBaseSimple<cef_box_layout_settings_t> {
 public:
  using base_type = CefStructBaseSimple<cef_box_layout_settings_t>;
  using base_type::CefStructBaseSimple;
  using base_type::operator=;

  CefBoxLayoutSettings() { cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH; }
};

///
/// Class representing IME composition underline.
///
using CefCompositionUnderline =
    CefStructBaseSimple<cef_composition_underline_t>;

///
/// Class representing CefAudioParameters settings
///
using CefAudioParameters = CefStructBaseSimple<cef_audio_parameters_t>;

struct CefMediaSinkDeviceInfoTraits {
  using struct_type = cef_media_sink_device_info_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->ip_address);
    cef_string_clear(&s->model_name);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    cef_string_set(src->ip_address.str, src->ip_address.length,
                   &target->ip_address, copy);
    target->port = src->port;
    cef_string_set(src->model_name.str, src->model_name.length,
                   &target->model_name, copy);
  }
};

///
/// Class representing MediaSink device info.
///
using CefMediaSinkDeviceInfo = CefStructBase<CefMediaSinkDeviceInfoTraits>;

///
/// Class representing accelerated paint info.
///
using CefAcceleratedPaintInfo =
    CefStructBaseSimple<cef_accelerated_paint_info_t>;

struct CefTaskInfoTraits {
  using struct_type = cef_task_info_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) { cef_string_clear(&s->title); }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    target->id = src->id;
    target->type = src->type;
    target->is_killable = src->is_killable;
    cef_string_set(src->title.str, src->title.length, &target->title, copy);
    target->cpu_usage = src->cpu_usage;
    target->number_of_processors = src->number_of_processors;
    target->memory = src->memory;
    target->gpu_memory = src->gpu_memory;
    target->is_gpu_memory_inflated = src->is_gpu_memory_inflated;
  }
};

///
/// Class representing task information.
///
using CefTaskInfo = CefStructBase<CefTaskInfoTraits>;

struct CefLinuxWindowPropertiesTraits {
  using struct_type = cef_linux_window_properties_t;

  static inline void init(struct_type* s) { s->size = sizeof(struct_type); }

  static inline void clear(struct_type* s) {
    cef_string_clear(&s->wayland_app_id);
    cef_string_clear(&s->wm_class_class);
    cef_string_clear(&s->wm_class_name);
    cef_string_clear(&s->wm_role_name);
  }

  static inline void set(const struct_type* src,
                         struct_type* target,
                         bool copy) {
    cef_string_set(src->wayland_app_id.str, src->wayland_app_id.length,
                   &target->wayland_app_id, copy);
    cef_string_set(src->wm_class_class.str, src->wm_class_class.length,
                   &target->wm_class_class, copy);
    cef_string_set(src->wm_class_name.str, src->wm_class_name.length,
                   &target->wm_class_name, copy);
    cef_string_set(src->wm_role_name.str, src->wm_role_name.length,
                   &target->wm_role_name, copy);
  }
};

///
/// Class representing the Linux-specific window properties required
/// for the window managers to correct group and display the window.
///
using CefLinuxWindowProperties = CefStructBase<CefLinuxWindowPropertiesTraits>;

#endif  // CEF_INCLUDE_INTERNAL_CEF_TYPES_WRAPPERS_H_
