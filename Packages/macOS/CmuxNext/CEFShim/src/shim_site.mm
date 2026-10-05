// Site state for Page Info through CEF's own API (ABI 3): content settings of
// the browser's request context (Chromium's HostContentSettingsMap, the
// store Chromium's Page Info edits), the context's cookie manager, and the
// visible navigation entry's SSL status.

#include <cstdlib>
#include <cstring>

#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_ssl_status.h"
#include "include/cef_task.h"
#include "include/cef_x509_certificate.h"
#include "shim_internal.h"

using namespace cmux_shim;

namespace {

struct ContentType {
  const char* name;
  cef_content_setting_types_t type;
};

// Names are SitePermissionKind raw values on the Swift side.
constexpr ContentType kContentTypes[] = {
    {"location", CEF_CONTENT_SETTING_TYPE_GEOLOCATION},
    {"camera", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA},
    {"microphone", CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC},
    {"notifications", CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
    {"javascript", CEF_CONTENT_SETTING_TYPE_JAVASCRIPT},
    {"images", CEF_CONTENT_SETTING_TYPE_IMAGES},
    {"popups", CEF_CONTENT_SETTING_TYPE_POPUPS},
    {"sound", CEF_CONTENT_SETTING_TYPE_SOUND},
    {"automaticDownloads", CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS},
    {"midi", CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX},
    {"usb", CEF_CONTENT_SETTING_TYPE_USB_GUARD},
    {"serial", CEF_CONTENT_SETTING_TYPE_SERIAL_GUARD},
    {"hid", CEF_CONTENT_SETTING_TYPE_HID_GUARD},
    {"clipboard", CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE},
    {"sensors", CEF_CONTENT_SETTING_TYPE_SENSORS},
    {"bluetooth", CEF_CONTENT_SETTING_TYPE_BLUETOOTH_GUARD},
    {"fileEditing", CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_WRITE_GUARD},
    {"windowManagement", CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT},
    {"localFonts", CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS},
    {"insecureContent", CEF_CONTENT_SETTING_TYPE_MIXEDSCRIPT},
    {"backgroundSync", CEF_CONTENT_SETTING_TYPE_BACKGROUND_SYNC},
    {"autoPictureInPicture", CEF_CONTENT_SETTING_TYPE_AUTO_PICTURE_IN_PICTURE},
    {"thirdPartySignIn", CEF_CONTENT_SETTING_TYPE_FEDERATED_IDENTITY_API},
};

bool LookupType(const char* name, cef_content_setting_types_t* out) {
  if (!name) {
    return false;
  }
  for (const ContentType& entry : kContentTypes) {
    if (std::strcmp(entry.name, name) == 0) {
      *out = entry.type;
      return true;
    }
  }
  return false;
}

CefRefPtr<CefRequestContext> ContextOf(int browser_id) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  return browser ? browser->GetHost()->GetRequestContext() : nullptr;
}

char* Owned(const std::string& text) {
  char* out = static_cast<char*>(std::malloc(text.size() + 1));
  if (out) {
    std::memcpy(out, text.c_str(), text.size() + 1);
  }
  return out;
}

void EmitOnUI(int browser_id, int reply, int64_t a, const std::string& json) {
  class EmitTask : public CefTask {
   public:
    EmitTask(int browser_id, int reply, int64_t a, std::string json)
        : browser_id_(browser_id), reply_(reply), a_(a), json_(std::move(json)) {}
    void Execute() override { Emit(CMUX_SHIM_REPLY, browser_id_, reply_, a_, 0, json_); }

   private:
    int browser_id_;
    int reply_;
    int64_t a_;
    std::string json_;
    IMPLEMENT_REFCOUNTING(EmitTask);
  };
  if (CefCurrentlyOn(TID_UI)) {
    Emit(CMUX_SHIM_REPLY, browser_id, reply, a, 0, json);
  } else {
    CefPostTask(TID_UI, new EmitTask(browser_id, reply, a, json));
  }
}

// Collects every cookie and replies with [{name, domain, path}] when CEF
// releases the visitor (after the last cookie, or at once when none).
class CookieCollector : public CefCookieVisitor {
 public:
  CookieCollector(int browser_id, int reply) : browser_id_(browser_id), reply_(reply), list_(CefListValue::Create()) {}
  ~CookieCollector() override {
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetList(list_);
    EmitOnUI(browser_id_, reply_, 1, CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString());
  }

  bool Visit(const CefCookie& cookie, int count, int total, bool& delete_cookie) override {
    CefRefPtr<CefDictionaryValue> entry = CefDictionaryValue::Create();
    entry->SetString("name", CefString(&cookie.name));
    entry->SetString("domain", CefString(&cookie.domain));
    entry->SetString("path", CefString(&cookie.path));
    list_->SetDictionary(list_->GetSize(), entry);
    delete_cookie = false;
    return true;
  }

 private:
  int browser_id_;
  int reply_;
  CefRefPtr<CefListValue> list_;
  IMPLEMENT_REFCOUNTING(CookieCollector);
};

class DeleteReply : public CefDeleteCookiesCallback {
 public:
  DeleteReply(int browser_id, int reply) : browser_id_(browser_id), reply_(reply) {}
  void OnComplete(int num_deleted) override { EmitOnUI(browser_id_, reply_, num_deleted, "[]"); }

 private:
  int browser_id_;
  int reply_;
  IMPLEMENT_REFCOUNTING(DeleteReply);
};

std::string Base64(CefRefPtr<CefBinaryValue> der) {
  if (!der || der->GetSize() == 0) {
    return std::string();
  }
  std::string bytes(der->GetSize(), '\0');
  der->GetData(bytes.data(), bytes.size(), 0);
  return CefBase64Encode(bytes.data(), bytes.size()).ToString();
}

}  // namespace

extern "C" {

int cmux_shim_content_setting(int browser_id, const char* url, const char* type) {
  cef_content_setting_types_t content_type;
  CefRefPtr<CefRequestContext> context = ContextOf(browser_id);
  if (!context || !LookupType(type, &content_type)) {
    return -1;
  }
  CefString target(url ? url : "");
  return context->GetContentSetting(target, target, content_type);
}

int cmux_shim_set_content_setting(int browser_id, const char* url, const char* type, int value) {
  cef_content_setting_types_t content_type;
  CefRefPtr<CefRequestContext> context = ContextOf(browser_id);
  if (!context || !url || !LookupType(type, &content_type) || value < 0 ||
      value >= CEF_CONTENT_SETTING_VALUE_NUM_VALUES) {
    return 0;
  }
  // "" sets the profile default (CEF ignores it for an incognito context).
  CefString target(url);
  context->SetContentSetting(target, target, content_type, static_cast<cef_content_setting_values_t>(value));
  return 1;
}

int cmux_shim_visit_cookies(int browser_id, int reply) {
  CefRefPtr<CefRequestContext> context = ContextOf(browser_id);
  CefRefPtr<CefCookieManager> manager = context ? context->GetCookieManager(nullptr) : nullptr;
  return manager && manager->VisitAllCookies(new CookieCollector(browser_id, reply)) ? 1 : 0;
}

int cmux_shim_delete_cookies(int browser_id, int reply, const char* url, const char* name) {
  CefRefPtr<CefRequestContext> context = ContextOf(browser_id);
  CefRefPtr<CefCookieManager> manager = context ? context->GetCookieManager(nullptr) : nullptr;
  if (!manager || !url || !*url) {
    return 0;
  }
  return manager->DeleteCookies(url, name ? name : "", new DeleteReply(browser_id, reply)) ? 1 : 0;
}

char* cmux_shim_ssl_status(int browser_id) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  CefRefPtr<CefNavigationEntry> entry = browser ? browser->GetHost()->GetVisibleNavigationEntry() : nullptr;
  CefRefPtr<CefSSLStatus> status = entry ? entry->GetSSLStatus() : nullptr;
  if (!status) {
    return nullptr;
  }
  CefRefPtr<CefDictionaryValue> result = CefDictionaryValue::Create();
  result->SetBool("secure", status->IsSecureConnection());
  result->SetInt("certStatus", status->GetCertStatus());
  result->SetInt("contentStatus", status->GetContentStatus());
  result->SetInt("sslVersion", status->GetSSLVersion());
  result->SetString("url", entry->GetURL());
  CefRefPtr<CefListValue> chain = CefListValue::Create();
  if (CefRefPtr<CefX509Certificate> certificate = status->GetX509Certificate()) {
    chain->SetString(0, Base64(certificate->GetDEREncoded()));
    CefX509Certificate::IssuerChainBinaryList issuers;
    certificate->GetDEREncodedIssuerChain(issuers);
    for (const CefRefPtr<CefBinaryValue>& issuer : issuers) {
      chain->SetString(chain->GetSize(), Base64(issuer));
    }
  }
  result->SetList("chain", chain);
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetDictionary(result);
  return Owned(CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString());
}

void cmux_shim_free_owned(char* s) {
  std::free(s);
}

}  // extern "C"
