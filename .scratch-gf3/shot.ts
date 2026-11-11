// After-image of the program mark's tooltip (message.senderProgram) from the built gallery.
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
const output = process.env.FAST_CHECKS_OUT ?? "/tmp/out";
const gallery = path.resolve(process.cwd(), "webviews/dist/gallery");
await mkdir(output, { recursive: true });
const server = Bun.serve({ port: 0, async fetch(request) {
  const name = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "");
  const file = path.resolve(gallery, name || "index.html");
  if (!file.startsWith(`${gallery}/`)) return new Response("forbidden", { status: 403 });
  const blob = Bun.file(file);
  return (await blob.exists()) ? new Response(blob) : new Response("not found", { status: 404 });
}});
const browser = await chromium.launch({ headless: true });
const readback: Record<string, unknown> = {};
try {
  for (const scheme of ["light", "dark"]) {
    const page = await (await browser.newContext({ deviceScaleFactor: 2, colorScheme: scheme as "light" | "dark", viewport: { width: 760, height: 520 } })).newPage();
    const params = new URLSearchParams({ entry: "agent-pane.message-row-kinds", variant: "card-open",
      frame: "component", colorScheme: scheme, width: "normal" });
    await page.goto(`http://127.0.0.1:${server.port}/frame.html?${params}`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 30_000 });
    const mark = page.locator(".cv-unverified.is-program").first();
    await mark.scrollIntoViewIfNeeded();
    const title = await mark.getAttribute("title");
    const label = await mark.getAttribute("aria-label");
    readback[scheme] = { title, label };
    // Headless Chromium draws no native tooltip: draw the title text where the tooltip opens.
    await mark.evaluate((el, text) => {
      const r = el.getBoundingClientRect();
      const tip = document.createElement("div");
      tip.textContent = text ?? "";
      Object.assign(tip.style, { position: "fixed", left: `${r.left}px`, top: `${r.bottom + 6}px`, whiteSpace: "pre",
        font: "12px -apple-system, system-ui, sans-serif", padding: "4px 8px", borderRadius: "6px", zIndex: "9999",
        background: "Canvas", color: "CanvasText", border: "1px solid GrayText", boxShadow: "0 2px 8px rgba(0,0,0,.25)" });
      document.body.appendChild(tip);
    }, title);
    const box = (await mark.boundingBox())!;
    await page.screenshot({ path: path.join(output, `program-mark-tooltip-${scheme}.png`),
      clip: { x: 0, y: Math.max(0, box.y - 60), width: 760, height: 200 } });
  }
} finally { await browser.close(); server.stop(); }
await writeFile(path.join(output, "readback.json"), JSON.stringify(readback, null, 2));
console.log("READBACK", JSON.stringify(readback));
