// Custom schemes every CEF process registers at startup, in one place: the
// browser process App (shim_client.mm) and the helper processes' CefApp
// (helper_main.mm) both call RegisterCustomSchemes, so the options can never
// differ between processes.
#ifndef CMUX_SHIM_PAGE_SCHEME_REGISTRATION_H_
#define CMUX_SHIM_PAGE_SCHEME_REGISTRATION_H_

#include "cmux_page_path.h"
#include "include/cef_scheme.h"

namespace cmux_shim {

// cmux-page://<id>/: app pages with an origin of their own per id
// (standard, so the host is the origin), a secure context, and CORS and
// fetch() within the scheme.
inline constexpr int kCmuxPageSchemeOptions = CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                                              CEF_SCHEME_OPTION_CORS_ENABLED | CEF_SCHEME_OPTION_FETCH_ENABLED;

inline void RegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) {
  registrar->AddCustomScheme(kCmuxPageScheme, kCmuxPageSchemeOptions);
}

}  // namespace cmux_shim

#endif  // CMUX_SHIM_PAGE_SCHEME_REGISTRATION_H_
