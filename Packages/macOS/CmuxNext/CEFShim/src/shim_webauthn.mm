// WebAuthn ceremonies in the embedder (fork API 33, Chromium 157 line;
// cef_cmux.h cmux_set_webauthn_delegate and cmux_webauthn_complete). A page
// nobody sees (a detached page, a remote-presentation page) or a tab in
// CMUX_WEBAUTHN_MODE_DELEGATE cannot show Chromium's WebAuthn UI or the
// system passkey sheet; with this delegate the request comes to cmux, which
// asks the person in its visible window and runs the ceremony itself
// (CEFWebAuthnPrompts on the Swift side).
//
// Both fork calls are found with dlsym (shim_process.mm). The 157 line does
// not have 31 and 32, so the API number proves nothing: a fork without the
// calls (API 30, cef-157.0.0-cmux.45 and 156 cmux.44) gets no delegate, and
// its detached pages keep refusing with NotAllowedError.
//
// The pinned artifact's cef_cmux.h may predate API 33, so the two structs are
// mirrored here; `size` guards every field read.

#include <cstddef>
#include <string>

#include "include/cef_parser.h"
#include "include/cef_values.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

// cmux_webauthn_request_t (API 33). Fields are only appended.
struct ForkWebAuthnRequest {
  int size;
  int request_id;
  int browser_id;
  int type;
  int mediation;
  const char* origin;
  const char* top_origin;
  int cross_origin;
  const char* rp_id;
  const char* options_json;
  int user_activation;
  int tab_mode;
  int detached;
  int main_frame;
};

// cmux_webauthn_delegate_t (API 33).
struct ForkWebAuthnDelegate {
  int size;
  void (*on_request)(void* context, const ForkWebAuthnRequest* request);
  void (*on_cancel)(void* context, int request_id, int reason);
  void* context;
  int platform_authenticator;
  int conditional_mediation;
};

struct WebAuthnHost {
  cmux_shim_webauthn_request_fn request = nullptr;
  cmux_shim_webauthn_cancel_fn cancel = nullptr;
  void* ctx = nullptr;
};

WebAuthnHost& webauthn_host() {
  static WebAuthnHost h;
  return h;
}

// The fork's request struct covers `end` bytes.
bool Covers(const ForkWebAuthnRequest* request, size_t end) {
  return request->size > 0 && static_cast<size_t>(request->size) >= end;
}

std::string Text(const char* value) {
  return value ? value : "";
}

// The request as one JSON object for the host (CEFWebAuthnRequest decodes
// it). The fork's strings live only during this call, so they are copied
// here; the host may answer inside the call or later.
void RequestTrampoline(void*, const ForkWebAuthnRequest* request) {
  if (!request || !Covers(request, offsetof(ForkWebAuthnRequest, browser_id))) return;
  const WebAuthnHost& h = webauthn_host();
  if (!h.request || !Covers(request, offsetof(ForkWebAuthnRequest, main_frame) + sizeof(int))) {
    // A host that left, or a request this shim cannot read: the page gets an answer, never a hang.
    if (fork_api().webauthn_complete) fork_api().webauthn_complete(request->request_id, nullptr, "NotAllowedError", nullptr);
    return;
  }
  CefRefPtr<CefDictionaryValue> object = CefDictionaryValue::Create();
  object->SetInt("request_id", request->request_id);
  object->SetInt("browser_id", request->browser_id);
  object->SetInt("type", request->type);
  object->SetInt("mediation", request->mediation);
  object->SetString("origin", Text(request->origin));
  object->SetString("top_origin", Text(request->top_origin));
  object->SetBool("cross_origin", request->cross_origin != 0);
  object->SetString("rp_id", Text(request->rp_id));
  object->SetString("options_json", Text(request->options_json));
  object->SetBool("user_activation", request->user_activation != 0);
  object->SetInt("tab_mode", request->tab_mode);
  object->SetBool("detached", request->detached != 0);
  object->SetBool("main_frame", request->main_frame != 0);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(object);
  const std::string json = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
  h.request(h.ctx, json.c_str());
}

void CancelTrampoline(void*, int request_id, int reason) {
  const WebAuthnHost& h = webauthn_host();
  if (h.cancel) h.cancel(h.ctx, request_id, reason);
}

}  // namespace

void RemoveWebAuthnDelegate() {
  webauthn_host() = WebAuthnHost();
  if (fork_api().set_webauthn_delegate) fork_api().set_webauthn_delegate(nullptr);
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

int cmux_shim_webauthn_set_delegate(cmux_shim_webauthn_request_fn on_request, cmux_shim_webauthn_cancel_fn on_cancel,
                                    void* ctx, int platform_authenticator) {
  if (!fork_api().set_webauthn_delegate || !fork_api().webauthn_complete) return 0;
  if (!on_request) {
    RemoveWebAuthnDelegate();
    return 1;
  }
  webauthn_host() = WebAuthnHost{on_request, on_cancel, ctx};
  // The fork reads the struct during the call; static keeps it valid anyway.
  static ForkWebAuthnDelegate delegate;
  delegate = ForkWebAuthnDelegate{};
  delegate.size = static_cast<int>(sizeof(ForkWebAuthnDelegate));
  delegate.on_request = RequestTrampoline;
  delegate.on_cancel = CancelTrampoline;
  delegate.context = nullptr;
  delegate.platform_authenticator = platform_authenticator ? 1 : 0;
  // Conditional (autofill) and ambient gets stay refused until cmux offers
  // passkeys in its own autofill UI.
  delegate.conditional_mediation = 0;
  const int result = fork_api().set_webauthn_delegate(&delegate);
  if (result != 1) webauthn_host() = WebAuthnHost();
  return result;
}

int cmux_shim_webauthn_delegate_tab(int browser_id) {
  // CMUX_WEBAUTHN_MODE_DELEGATE (cef_cmux.h). Only while cmux's delegate is
  // set: without one the fork refuses every request of a DELEGATE tab, and a
  // fork before API 33 does not know the mode (it returns 0).
  constexpr int kWebAuthnModeDelegate = 2;
  if (!fork_api().set_webauthn_mode || !webauthn_host().request) return 0;
  return fork_api().set_webauthn_mode(browser_id, kWebAuthnModeDelegate);
}

int cmux_shim_webauthn_complete(int request_id, const char* response_json, const char* error_name,
                                const char* error_message) {
  if (!fork_api().webauthn_complete) return 0;
  return fork_api().webauthn_complete(request_id, response_json, error_name, error_message);
}

}  // extern "C"
