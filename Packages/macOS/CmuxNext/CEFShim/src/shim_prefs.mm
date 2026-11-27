// Profile preferences for the password and autofill settings
// (cmux_shim_pref_*). Only an allowlist of boolean preferences is reachable,
// through the request context the shim keeps per profile cache path.
// UI thread only.

#include <cstdlib>
#include <cstring>
#include <utility>

#include "include/cef_parser.h"
#include "include/cef_preference.h"
#include "shim_internal.h"

namespace cmux_shim {

namespace {

bool Allowed(const char* name) {
  static const char* const kAllowed[] = {
      "credentials_enable_service",
      "credentials_enable_autosignin",
      "autofill.profile_enabled",
      "autofill.credit_card_enabled",
      "password_manager.biometric_authentication_filling",
  };
  if (!name) return false;
  for (const char* allowed : kAllowed) {
    if (std::strcmp(name, allowed) == 0) return true;
  }
  return false;
}

CefRefPtr<CefRequestContext> ContextOf(const char* profile_cache_path) {
  if (!profile_cache_path || !*profile_cache_path) return nullptr;
  return ExistingRequestContext(profile_cache_path);
}

class Observer : public CefPreferenceObserver {
 public:
  explicit Observer(std::string cache_path) : cache_path_(std::move(cache_path)) {}

  void OnPreferenceChanged(const CefString& name) override {
    Emit(CMUX_SHIM_PREF_CHANGED, 0, 0, 0, 0, name.ToString(), cache_path_);
  }

 private:
  const std::string cache_path_;
  IMPLEMENT_REFCOUNTING(Observer);
};

// (profile cache path, preference name) -> its observer registration.
std::map<std::pair<std::string, std::string>, CefRefPtr<CefRegistration>>& watches() {
  static std::map<std::pair<std::string, std::string>, CefRefPtr<CefRegistration>> map;
  return map;
}

}  // namespace

void ForgetPreferenceWatches(const std::string& key) {
  auto& map = watches();
  for (auto it = map.begin(); it != map.end();) {
    it = it->first.first == key ? map.erase(it) : std::next(it);
  }
}

void ReleasePreferenceWatches() {
  watches().clear();
}

}  // namespace cmux_shim

using namespace cmux_shim;

extern "C" {

char* cmux_shim_pref_get(const char* profile_cache_path, const char* pref_name) {
  if (!Allowed(pref_name)) return nullptr;
  CefRefPtr<CefRequestContext> context = ContextOf(profile_cache_path);
  if (!context) return nullptr;
  CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
  CefRefPtr<CefValue> value = context->GetPreference(pref_name);
  if (value && value->GetType() == VTYPE_BOOL) {
    dict->SetBool("value", value->GetBool());
  } else {
    dict->SetNull("value");
  }
  dict->SetBool("modifiable", context->CanSetPreference(pref_name));
  CefRefPtr<CefValue> root = CefValue::Create();
  root->SetDictionary(dict);
  std::string json = CefWriteJSON(root, JSON_WRITER_DEFAULT).ToString();
  // Freed with cmux_shim_free_owned (std::free).
  char* out = static_cast<char*>(std::malloc(json.size() + 1));
  if (out) std::memcpy(out, json.c_str(), json.size() + 1);
  return out;
}

int cmux_shim_pref_set_bool(const char* profile_cache_path, const char* pref_name, int value) {
  if (!Allowed(pref_name)) return 0;
  CefRefPtr<CefRequestContext> context = ContextOf(profile_cache_path);
  if (!context) return -1;
  if (!context->CanSetPreference(pref_name)) return 0;
  CefRefPtr<CefValue> pref = CefValue::Create();
  pref->SetBool(value != 0);
  CefString error;
  return context->SetPreference(pref_name, pref, error) ? 1 : -1;
}

int cmux_shim_pref_watch(const char* profile_cache_path, const char* pref_name, int enabled) {
  if (!Allowed(pref_name) || !profile_cache_path || !*profile_cache_path) return 0;
  const auto key = std::make_pair(std::string(profile_cache_path), std::string(pref_name));
  if (!enabled) {
    watches().erase(key);
    return 1;
  }
  if (watches().count(key)) return 1;
  CefRefPtr<CefRequestContext> context = ContextOf(profile_cache_path);
  if (!context) return 0;
  CefRefPtr<CefRegistration> registration = context->AddPreferenceObserver(pref_name, new Observer(key.first));
  if (!registration) return 0;
  watches()[key] = registration;
  return 1;
}

}  // extern "C"
