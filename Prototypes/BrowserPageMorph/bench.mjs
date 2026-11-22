// Bench for the page morph prototype: tab-switch variants and injected
// cross-document View Transitions, in real Chromium via playwright-core.
//   npm i playwright-core && node bench.mjs [--chromium PATH] [--headless] [--out DIR]
// Writes results.json and clips (webm) to --out (default ./out).
import { chromium } from "playwright-core";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const OUT = path.resolve(arg("--out", path.join(here, "out")));
const HEADLESS = process.argv.includes("--headless");
fs.mkdirSync(OUT, { recursive: true });

const types = { ".html": "text/html", ".js": "text/javascript" };
const server = http.createServer((req, res) => {
  const p = path.join(here, decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!p.startsWith(here) || !fs.existsSync(p) || fs.statSync(p).isDirectory()) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": types[path.extname(p)] || "application/octet-stream", "cache-control": "no-store" });
  fs.createReadStream(p).pipe(res);
}).listen(0);
const PORT = server.address().port;
const BASE = `http://localhost:${PORT}`;

const browser = await chromium.launch({ headless: HEADLESS, executablePath: arg("--chromium", undefined) });
const VIEW = { width: 1280, height: 800 };
const VARIANTS = ["none", "crossfade", "veil", "chrome", "veil+chrome", "slide"];

// Seeded arbitrary jumps over the ten tabs, plus back/forward presses.
function sequence(n, seed = 7) {
  let s = seed; const rnd = () => (s = (s * 1103515245 + 12345) % 2 ** 31) / 2 ** 31;
  const keys = []; let cur = 0;
  for (let k = 0; k < n; k++) {
    if (k % 7 === 6) { keys.push("["); continue; }
    if (k % 7 === 0 && k) { keys.push("]"); continue; }
    let j; do { j = Math.floor(rnd() * 10); } while (j === cur); cur = j; keys.push(String(j));
  }
  return keys;
}

async function openSim(ctx, variant, slow = 1) {
  const page = await ctx.newPage();
  await page.goto(`${BASE}/index.html?variant=${encodeURIComponent(variant)}&slow=${slow}`);
  await page.waitForSelector("body[data-ready='1']");
  await page.waitForFunction(() => window.__frameMs);
  await page.waitForTimeout(300);
  return page;
}

const results = { when: new Date().toISOString(), ua: browser.version(), headless: HEADLESS, switches: {}, cancel: {}, vt: {} };

// 1. Tab switches: 42 arbitrary jumps per variant.
const ONLY_VT = process.argv.includes("--only-vt");
const ctx = await browser.newContext({ viewport: VIEW });
for (const v of ONLY_VT ? [] : VARIANTS) {
  const page = await openSim(ctx, v);
  for (const key of sequence(42)) { await page.keyboard.press(key); await page.waitForTimeout(450); }
  results.switches[v] = await page.evaluate(() => window.__morph.log.switches.filter(s => s.how !== "init"));
  // Cancel: switch then a wheel 30 ms later; the overlay must be gone on the next frame.
  await page.evaluate(() => { window.__morph.log.switches.length = 0; window.__morph.log.cancels.length = 0; });
  for (const [a, b] of [[0, 2], [2, 0], [8, 3], [3, 1], [9, 5], [5, 4]]) {
    await page.evaluate(a => window.__morph.switchTo(a), a); await page.waitForTimeout(400);
    await page.evaluate(b => { window.__morph.switchTo(b); setTimeout(() => window.dispatchEvent(new WheelEvent("wheel", { deltaY: 40 })), 30); }, b);
    await page.waitForTimeout(450);
  }
  results.cancel[v] = await page.evaluate(() => ({ cancels: window.__morph.log.cancels, switches: window.__morph.log.switches }));
  await page.close();
}
await ctx.close();
const save = () => fs.writeFileSync(path.join(OUT, "results.json"), JSON.stringify(results, null, 1));
save();

// 2. Clips: the same light/dark tour per variant, real time; slow x4 for the overlay variants.
const CLIPS = !process.argv.includes("--no-clips");
const tour = ["2", "0", "1", "3", "8", "9", "7", "5", "4", "6"];
for (const [v, slow] of !CLIPS || ONLY_VT ? [] : [...VARIANTS.map(v => [v, 1]), ["crossfade", 4], ["veil+chrome", 4], ["slide", 4]]) {
  const dir = path.join(OUT, "tmp-video"); fs.rmSync(dir, { recursive: true, force: true });
  const c = await browser.newContext({ viewport: VIEW, recordVideo: { dir, size: { width: 960, height: 600 } } });
  const page = await openSim(c, v, slow);
  for (const key of tour) { await page.keyboard.press(key); await page.waitForTimeout(500 * Math.max(1, slow / 2)); }
  const vid = page.video(); await c.close();
  await vid.saveAs(path.join(OUT, `switch-${v.replace("+", "-")}${slow > 1 ? `-slow${slow}` : ""}.webm`));
}

// 3. Cross-document View Transitions, injected at document start like CEFDocumentScripts would.
const VT_CSS = { off: null, auto: "@view-transition{navigation:auto}", fast: "@view-transition{navigation:auto}::view-transition-group(*),::view-transition-old(*),::view-transition-new(*){animation-duration:120ms}" };
for (const [mode, css] of Object.entries(VT_CSS)) {
  const c = await browser.newContext({ viewport: VIEW });
  if (css) await c.addInitScript(css => {
    const s = new CSSStyleSheet(); s.replaceSync(css);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, s];
  }, css);
  const page = await c.newPage();
  await page.goto(`${BASE}/vt/page.html?id=0`);
  const runs = [];
  for (let k = 0; k < 16; k++) {
    const cross = k % 4 === 3;
    await page.evaluate(() => { window.__leaving = true; });
    await page.click(cross ? "#cross" : "#same");
    await page.waitForFunction(() => !window.__leaving && window.__vt && window.__vt.reveal && window.__vt.frames.length > 5 && performance.now() - window.__vt.reveal > 500);
    runs.push(await page.evaluate(cross => {
      const fcp = performance.getEntriesByType("paint").find(e => e.name === "first-contentful-paint");
      const nav = performance.getEntriesByType("navigation")[0];
      const f = __vt.frames, gaps = f.slice(1).map((x, i) => x - f[i]);
      return { cross, hadTransition: __vt.hadTransition, fcp: fcp && +fcp.startTime.toFixed(1), reveal: +__vt.reveal.toFixed(1),
        ready: __vt.ready && +__vt.ready.toFixed(1), finished: __vt.finished && +__vt.finished.toFixed(1),
        responseEnd: +nav.responseEnd.toFixed(1), maxGap: +Math.max(...gaps).toFixed(1), gaps };
    }, cross));
  }
  results.vt[mode] = runs;
  save();
  await c.close();
}
// VT clip (slow-motion via a longer injected duration so the clip shows the effect).
for (const [mode, css] of !CLIPS ? [] : [["off", null], ["auto", VT_CSS.auto]]) {
  const dir = path.join(OUT, "tmp-video"); fs.rmSync(dir, { recursive: true, force: true });
  const c = await browser.newContext({ viewport: VIEW, recordVideo: { dir, size: { width: 960, height: 600 } } });
  if (css) await c.addInitScript(css => { const s = new CSSStyleSheet(); s.replaceSync(css); document.adoptedStyleSheets = [...document.adoptedStyleSheets, s]; }, css);
  const page = await c.newPage();
  await page.goto(`${BASE}/vt/page.html?id=0`); await page.waitForTimeout(500);
  for (let k = 0; k < 6; k++) { await page.click("#same"); await page.waitForTimeout(700); }
  const vid = page.video(); await c.close();
  await vid.saveAs(path.join(OUT, `vt-${mode}.webm`));
}
fs.rmSync(path.join(OUT, "tmp-video"), { recursive: true, force: true });

save();
await browser.close(); server.close();
console.log(`wrote ${OUT}/results.json`);
