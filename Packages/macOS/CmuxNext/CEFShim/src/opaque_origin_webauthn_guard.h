// Interim guard (renderer process): web content in an opaque-origin frame
// must not reach the browser-process DCHECK that aborted cmux NIGHTLY on
// 2026-10-04.
//
// CEF cmux.16 and older are non-official builds with DCHECKs on, so
// DCHECK(!caller_origin.opaque()) in
// AuthenticatorCommonImpl::GetWebAuthnRequestProxyIfActive aborts the browser
// process, which is the app. Three PublicKeyCredential methods reach it with
// no RP ID check first: isUserVerifyingPlatformAuthenticatorAvailable and
// getClientCapabilities (IsUvpaaAvailableInternal) and
// isConditionalMediationAvailable. navigator.credentials.create/get fail the
// RP ID check for an opaque origin before they get there.
//
// The real fix is CEF cmux.17 (dcheck_always_on=false,
// https://github.com/manaflow-ai/cef/pull/8). Remove this guard once
// cef-manifest.json pins cmux.17 or later (plans/cmux-next/crash-elimination.md).
#ifndef CMUX_SHIM_OPAQUE_ORIGIN_WEBAUTHN_GUARD_H_
#define CMUX_SHIM_OPAQUE_ORIGIN_WEBAUTHN_GUARD_H_

#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"

namespace cmux_shim {

// CEF calls OnContextCreated before Blink installs [SecureContext]
// interfaces (LocalWindowProxy::InstallConditionalFeatures), so the real
// PublicKeyCredential does not exist yet and cannot be patched. The guard
// defines a stand-in PublicKeyCredential on the opaque-origin global first,
// as a non-writable, non-configurable property; Blink's later lazy install
// of the real one then leaves it in place. The stand-in answers the three
// methods in the renderer (no platform authenticator, no conditional UI, no
// capabilities) and cannot be constructed. The real constructor is never
// created in that context, so page script cannot reach it. WebAuthn cannot
// work from an opaque origin anyway: create/get fail the RP ID check.
inline constexpr char kOpaqueOriginWebAuthnGuard[] =
    "(()=>{const answers={isUserVerifyingPlatformAuthenticatorAvailable:false,"
    "isConditionalMediationAvailable:false,getClientCapabilities:{}};"
    "function PublicKeyCredential(){throw new TypeError('Illegal constructor');}"
    "for(const name of Object.keys(answers)){const answer=answers[name];"
    "Object.defineProperty(PublicKeyCredential,name,{value:{[name](){return Promise.resolve("
    "typeof answer==='object'?{}:answer);}}[name],writable:false,enumerable:true,configurable:false});}"
    "Object.freeze(PublicKeyCredential.prototype);Object.freeze(PublicKeyCredential);"
    "Object.defineProperty(globalThis,'PublicKeyCredential',{value:PublicKeyCredential,"
    "writable:false,enumerable:false,configurable:false});})();";

class OpaqueOriginWebAuthnGuard : public CefRenderProcessHandler {
 public:
  // Runs for every context in the main world before page script. The cost
  // for a normal frame is one property read (`origin`); the script runs
  // only in secure opaque-origin frames.
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefV8Context> context) override {
    CefRefPtr<CefV8Value> global = context->GetGlobal();
    if (!global) {
      return;
    }
    CefRefPtr<CefV8Value> origin = global->GetValue("origin");
    if (!origin || !origin->IsString() || origin->GetStringValue() != "null") {
      return;
    }
    // Insecure contexts have no PublicKeyCredential; leave them as they are.
    CefRefPtr<CefV8Value> secure = global->GetValue("isSecureContext");
    if (!secure || !secure->IsBool() || !secure->GetBoolValue()) {
      return;
    }
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(kOpaqueOriginWebAuthnGuard, CefString(), 0, result, exception);
  }

 private:
  IMPLEMENT_REFCOUNTING(OpaqueOriginWebAuthnGuard);
};

}  // namespace cmux_shim

#endif  // CMUX_SHIM_OPAQUE_ORIGIN_WEBAUTHN_GUARD_H_
