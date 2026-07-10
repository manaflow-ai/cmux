(() => {
  const marker = document.createElement("div");
  marker.id = "cefkit-ext-marker";
  marker.textContent = "CEFKit extension active";
  marker.style.cssText =
    "position:fixed;bottom:8px;right:8px;z-index:2147483647;" +
    "background:#1a7f37;color:#fff;font:12px -apple-system,sans-serif;" +
    "padding:4px 8px;border-radius:6px;opacity:0.9;pointer-events:none;";
  const attach = () => document.body && document.body.appendChild(marker);
  if (document.body) {
    attach();
  } else {
    document.addEventListener("DOMContentLoaded", attach);
  }
})();
