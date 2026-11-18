// Custom schemes every CEF process registers at startup, in one place: the
// browser process App (shim_client.mm) and the helper processes' CefApp
// (helper_main.mm) both call RegisterCustomSchemes, so the options can never
// differ between processes. The renderer needs the code cache bit as much as
// the browser: Blink asks for a script's cached code only for a scheme it has
// as a code cache scheme.
#ifndef CMUX_SHIM_PAGE_SCHEME_REGISTRATION_H_
#define CMUX_SHIM_PAGE_SCHEME_REGISTRATION_H_

#include "cmux_page_path.h"
#include "include/cef_scheme.h"

namespace cmux_shim {

// cmux-page://<id>/ options (kCmuxPageSchemeOptions, cmux_page_path.h): each
// plain bit there must be CEF's.
static_assert(page_scheme_option::kStandard == CEF_SCHEME_OPTION_STANDARD);
static_assert(page_scheme_option::kSecure == CEF_SCHEME_OPTION_SECURE);
static_assert(page_scheme_option::kCorsEnabled == CEF_SCHEME_OPTION_CORS_ENABLED);
static_assert(page_scheme_option::kFetchEnabled == CEF_SCHEME_OPTION_FETCH_ENABLED);
// The code cache bit is the fork's, outside cef_scheme_options_t; it must stay
// clear of every CEF option.
static_assert(page_scheme_option::kCodeCache > CEF_SCHEME_OPTION_FETCH_ENABLED);
#ifdef CMUX_CEF_SCHEME_OPTION_CODE_CACHE
static_assert(page_scheme_option::kCodeCache == CMUX_CEF_SCHEME_OPTION_CODE_CACHE);
#endif

inline void RegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme(kCmuxPageScheme, kCmuxPageSchemeOptions);
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_PAGE_SCHEME_REGISTRATION_H_
