// Scratch (lane rail-hover-sweep, not committed): which CSS rules make a hover move restyle the whole page.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
const webviews = path.resolve(import.meta.dir, "../webviews");
const out = fs.mkdtempSync(path.join(os.tmpdir(), "sweep-culprit-"));
const env = { ...process.env, CMUX_LATENCY_OUT_DIR: out };
const vp = path.join(webviews, "node_modules/.bin/vp");
const b = spawnSync(vp, ["build", "--config", "vite.config.latency.ts"], { cwd: webviews, env, encoding: "utf8" });
if (b.status !== 0) throw new Error(b.stderr.slice(-2000));
const port = 5790 + Math.floor(Math.random() * 1000);
const server = spawn(vp, ["preview", "--config", "vite.config.latency.ts", "--port", String(port), "--strictPort"], { cwd: webviews, env, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 4000));
const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${port}/test/latency/flows.html?mock&turns=100&resident`);
  await page.waitForFunction(`document.documentElement.dataset.latencyFlowsReady === "true"`, undefined, { timeout: 180000 });
  if (await page.$("aside.acpmux-chat-inspector")) {
    await page.evaluate(() => (window as any).cmuxAcpmuxBridge.command("toggleSessionInfo"));
    await page.waitForSelector("aside.acpmux-chat-inspector", { state: "detached" });
  }
  await page.evaluate(() => {
    const t = document.querySelector<HTMLElement>(".acpmux-scroll")!; t.scrollTop = t.scrollHeight;
    const l = document.querySelector<HTMLElement>(".acpmux-minimap__list")!; l.scrollTop = l.scrollHeight;
  });
  await page.waitForTimeout(1500);
  const ticks = await page.evaluate(() => {
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const box = list.getBoundingClientRect();
    return [...list.querySelectorAll<HTMLElement>("[data-tick]")].map((t) => t.getBoundingClientRect()).filter((r) => r.height > 0 && r.top >= box.top + 32 && r.bottom <= box.bottom - 32).map((r) => ({ x: r.left + 8, y: r.top + 5 })).slice(0, 16);
  });
  const cdp = await context.newCDPSession(page);
  await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
  const metric = async () => Object.fromEntries(((await cdp.send("Performance.getMetrics")) as any).metrics.map((m: any) => [m.name, m.value]));
  const sweep = async () => {
    const a = await metric();
    for (const t of [...ticks, ...ticks.slice().reverse()]) {
      await page.mouse.move(t.x, t.y);
      await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0))));
    }
    const z = await metric();
    return { ms: ((z.RecalcStyleDuration - a.RecalcStyleDuration) * 1000) / (ticks.length * 2), n: (z.RecalcStyleCount - a.RecalcStyleCount) / (ticks.length * 2) };
  };
  // Every :has() rule, by sheet and index path.
  const list: string[] = await page.evaluate(() => {
    const found: string[] = [];
    (window as any).__rules = [];
    const walk = (rules: CSSRuleList) => { for (let i = 0; i < rules.length; i++) { const r = rules[i] as any; if (r instanceof CSSStyleRule) { if (r.selectorText.includes(":has(")) { (window as any).__rules.push(r); found.push(r.selectorText); } } else if (r.cssRules) walk(r.cssRules); } };
    for (const s of [...document.styleSheets]) { try { walk(s.cssRules); } catch {} }
    return found;
  });
  // Disable a rule by renaming its selector to one that matches nothing; restore after.
  const toggle = (i: number, off: boolean) => page.evaluate(([i, off]) => { const r = (window as any).__rules[i]; if (off) { r.__sel = r.selectorText; r.selectorText = ":not(*)"; } else r.selectorText = r.__sel; }, [i, off] as const);
  await sweep();
  const base = await sweep();
  console.log("BASE", JSON.stringify(base), "hasRules", list.length);
  const all = await (async () => { for (let i = 0; i < list.length; i++) await toggle(i, true); const v = await sweep(); for (let i = 0; i < list.length; i++) await toggle(i, false); return v; })();
  console.log("ALL_OFF", JSON.stringify(all));
  const results: Array<[number, number, string]> = [];
  for (let i = 0; i < list.length; i++) {
    await toggle(i, true);
    const v = await sweep();
    await toggle(i, false);
    results.push([base.ms - v.ms, v.ms, list[i]!]);
  }
  results.sort((a, b) => b[0] - a[0]);
  for (const [gain, ms, sel] of results.slice(0, 15)) console.log("CULPRIT", gain.toFixed(2), ms.toFixed(2), sel.slice(0, 400));
} finally {
  await browser.close(); server.kill(); fs.rmSync(out, { recursive: true, force: true });
}
