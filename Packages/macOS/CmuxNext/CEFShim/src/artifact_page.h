// Offline artifact documents for the shared CEF agent and artifacts pages. No CEF dependency;
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
    "frame-ancestors cmux-page://cmux.agent cmux-page://cmux.artifacts";

inline bool IsArtifactFrameURL(const std::string& url) {
  return url.substr(0, url.find_first_of("?#")) == kArtifactFrameURL;
}

// The canonical artifact route is shared by exactly these parent origins. A prefix
// match alone would also trust lookalike hosts, credentials or ports.
inline bool IsArtifactParentPageURL(const std::string& url) {
  if (IsArtifactFrameURL(url)) return false;
  for (const auto* origin : {"cmux-page://cmux.agent", "cmux-page://cmux.artifacts"}) {
    const std::string parent(origin);
    if (url.compare(0, parent.size(), parent) == 0 &&
        (url.size() == parent.size() || url[parent.size()] == '/' || url[parent.size()] == '?' ||
         url[parent.size()] == '#')) return true;
  }
  return false;
}

inline bool ArtifactContextRestricted(const std::string& frame, const std::string& parent) {
  return IsArtifactFrameURL(frame) || IsArtifactFrameURL(parent) ||
         (frame == "about:srcdoc" && IsArtifactParentPageURL(parent));
}

// Only an empty, direct child of an allowed page may load the bootstrap once.
// After commit, self navigation (including refresh), children and srcdoc
// replacement are denied, regardless of the destination's scheme.
inline bool ArtifactNavigationRefused(bool main, const std::string& frame, const std::string& parent,
                                      const std::string& target) {
  if (ArtifactContextRestricted(frame, parent)) return true;
  if (IsArtifactFrameURL(target)) {
    return main || target != kArtifactFrameURL || !IsArtifactParentPageURL(parent) ||
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
