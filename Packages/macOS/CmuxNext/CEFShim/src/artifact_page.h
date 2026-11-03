// Offline artifact documents for the shared CEF agent page. No CEF dependency;
// exercised by test-cmux-page-path-cpp.sh alongside the scheme's path policy.
#ifndef CMUX_SHIM_ARTIFACT_PAGE_H_
#define CMUX_SHIM_ARTIFACT_PAGE_H_

#include <string>

namespace cmux_shim {
inline constexpr char kArtifactFrameURL[] = "cmux-page://cmux.agent/__artifact";
inline constexpr char kArtifactCSP[] =
    "sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
    "img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; "
    "frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'; "
    "frame-ancestors cmux-page://cmux.agent";

inline bool IsArtifactFrameURL(const std::string& url) {
  return url.substr(0, url.find_first_of("?#")) == kArtifactFrameURL;
}

inline bool IsPageOriginURL(const std::string& url, const std::string& origin) {
  return url.compare(0, origin.size(), origin) == 0 &&
         (url.size() == origin.size() || url[origin.size()] == '/' || url[origin.size()] == '?' ||
          url[origin.size()] == '#');
}

inline bool IsAgentPageURL(const std::string& url) { return IsPageOriginURL(url, "cmux-page://cmux.agent"); }

// Pages whose srcdoc frames hold saved documents (PageDescriptor.passiveFrames): the agent page
// and the Artifacts page. Such a frame can neither navigate nor load anything but inline media.
inline bool IsPassiveFramePageURL(const std::string& url) {
  return IsAgentPageURL(url) || IsPageOriginURL(url, "cmux-page://cmux.artifacts");
}

inline bool ArtifactContextRestricted(const std::string& frame, const std::string& parent) {
  return IsArtifactFrameURL(frame) || IsArtifactFrameURL(parent) ||
         (frame == "about:srcdoc" && IsPassiveFramePageURL(parent));
}

// Only an empty, direct child of the agent page may load the bootstrap once.
// After commit, self navigation (including refresh), children and srcdoc
// replacement are denied, regardless of the destination's scheme.
inline bool ArtifactNavigationRefused(bool main, const std::string& frame, const std::string& parent,
                                      const std::string& target) {
  if (ArtifactContextRestricted(frame, parent)) return true;
  if (IsArtifactFrameURL(target)) {
    return main || target != kArtifactFrameURL || !IsAgentPageURL(parent) ||
           (!frame.empty() && frame != "about:blank");
  }
  return false;
}

inline bool ArtifactResourceAllowed(const std::string& url, bool image_media_or_font) {
  return image_media_or_font && (url.rfind("data:", 0) == 0 || url.rfind("blob:", 0) == 0);
}

// Same one-shot protocol as AgentPaneRenderFrame. The response's sandbox
// makes the origin opaque even if an embedder omits its iframe sandbox. A
// passive preview remains srcdoc with sandbox=""; only Run grants scripts.
inline char kArtifactDocument[] = R"HTML(<!doctype html>
<html><head><meta charset="utf-8"><script>
"use strict";
(function () {
  var host = parent;
  function size() {
    var body = document.body;
    host.postMessage({type:"cmux-render-size",height:Math.ceil(Math.max(
      document.documentElement.scrollHeight,body ? body.scrollHeight : 0))},"*");
  }
  function show(event) {
    var data = event.data;
    if (event.source !== host || !data || data.type !== "cmux-render" || typeof data.html !== "string") return;
    removeEventListener("message",show);
    document.open(); document.write(data.html); document.close();
    var theme = document.createElement("style");
    theme.textContent = typeof data.css === "string" ? data.css : "";
    var head = document.head || document.documentElement;
    head.insertBefore(theme,head.firstChild);
    new ResizeObserver(size).observe(document.documentElement);
    addEventListener("load",size); size();
  }
  addEventListener("message",show);
  host.postMessage({type:"cmux-render-ready"},"*");
})();
</script></head></html>)HTML";
}  // namespace cmux_shim
#endif  // CMUX_SHIM_ARTIFACT_PAGE_H_
