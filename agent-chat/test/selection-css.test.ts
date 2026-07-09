const css = await Bun.file("public/app.css").text();

for (const required of [
  "#root, #main",
  "user-select: none",
  "-webkit-user-select: none",
  "#messages {",
  "#messages *",
  "#messages button",
  ".msg .body .markdown-code pre",
  "scroll-padding-inline: 14px",
  "user-select: text",
]) {
  if (!css.includes(required)) throw new Error(`missing selection policy CSS: ${required}`);
}

if (/cursor\s*:\s*pointer/.test(css)) {
  throw new Error("cursor:pointer remains in app.css");
}
if (/\.turn-summary:hover,\n\.turn-activity-row:hover\s*\{\s*background:/.test(css)) {
  throw new Error("turn disclosure rows should not use filled hover backgrounds");
}

function zIndex(selector: string): number {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`${escaped}\\s*\\{[^}]*z-index:\\s*(\\d+)`, "s");
  const match = re.exec(css);
  if (!match) throw new Error(`missing z-index rule for ${selector}`);
  return Number(match[1]);
}

if (zIndex(".tooltip-positioner") <= zIndex(".select-positioner, .menu")) {
  throw new Error("tooltip layer should stack above menu/popover layers");
}

console.log("selection CSS policy: OK");

export {};
