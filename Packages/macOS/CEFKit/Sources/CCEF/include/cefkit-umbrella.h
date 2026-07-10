// CCEF umbrella: the CEF C API surface exposed to Swift. The sibling
// "include" symlink (created by scripts/fetch-cef.sh) points at the CEF
// distribution's include tree so CEF's internal "include/..." includes
// resolve against this directory.
#ifndef CEFKIT_UMBRELLA_H_
#define CEFKIT_UMBRELLA_H_

#include "include/cef_api_hash.h"
#include "include/cef_version.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_frame_handler_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_preference_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/capi/cef_task_capi.h"
#include "include/capi/cef_values_capi.h"

static const int cefkit_api_version_last = CEF_API_VERSION_LAST;

#endif  // CEFKIT_UMBRELLA_H_
