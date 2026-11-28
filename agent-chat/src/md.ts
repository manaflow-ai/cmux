// Minimal markdown -> HTML for assistant messages. Same rules as the prior
// vanilla renderer; output is used with dangerouslySetInnerHTML on trusted
// model output only.
function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function inlineMd(s: string): string {
  return s
    .replace(/`([^`]+)`/g, (_, c) => "<code>" + c + "</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|\s)\*([^*\s][^*]*)\*/g, "$1<em>$2</em>")
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
}
export function renderMd(text: string): string {
  const parts = text.split(/```/);
  let html = "";
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) {
      const nl = parts[i].indexOf("\n");
      const body = nl >= 0 ? parts[i].slice(nl + 1) : parts[i];
      html += "<pre><code>" + escapeHtml(body.replace(/\n$/, "")) + "</code></pre>";
      continue;
    }
    const lines = escapeHtml(parts[i]).split("\n");
    let para: string[] = [];
    let inList = false;
    const flushPara = () => {
      if (para.length) { html += "<p>" + inlineMd(para.join("<br>")) + "</p>"; para = []; }
    };
    const closeList = () => { if (inList) { html += "</ul>"; inList = false; } };
    for (const raw of lines) {
      const line = raw.trimEnd();
      const h = line.match(/^(#{1,4})\s+(.*)/);
      const li = line.match(/^\s*[-*]\s+(.*)/);
      if (!line.trim()) { flushPara(); closeList(); }
      else if (h) { flushPara(); closeList(); const lvl = Math.min(h[1].length + 2, 5); html += `<h${lvl}>` + inlineMd(h[2]) + `</h${lvl}>`; }
      else if (li) { flushPara(); if (!inList) { html += "<ul>"; inList = true; } html += "<li>" + inlineMd(li[1]) + "</li>"; }
      else { closeList(); para.push(line); }
    }
    flushPara(); closeList();
  }
  return html;
}
