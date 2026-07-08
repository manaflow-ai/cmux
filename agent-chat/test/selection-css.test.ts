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

console.log("selection CSS policy: OK");

export {};
