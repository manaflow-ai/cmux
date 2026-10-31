// Scratch (lane rail-hover-sweep, not committed): trace a hover sweep and summarize where main-thread time goes.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
const webviews = path.resolve(import.meta.dir, "../webviews");
const out = fs.mkdtempSync(path.join(os.tmpdir(), "sweep-trace-"));
const env = { ...process.env, CMUX_LATENCY_OUT_DIR: out };
const vp = path.join(webviews, "node_modules/.bin/vp");
const b = spawnSync(vp, ["build", "--config", "vite.config.latency.ts"], { cwd: webviews, env, encoding: "utf8" });
if (b.status !== 0) throw new Error(b.stderr.slice(-2000));
const port = 4790 + Math.floor(Math.random() * 1000);
const server = spawn(vp, ["preview", "--config", "vite.config.latency.ts", "--port", String(port), "--strictPort"], { cwd: webviews, env, stdio: "ignore" });
await new Promise((r) => setTimeout(r, 4000));
const browser = await chromium.launch({ headless: true });
const turns = process.env.TURNS ?? "100";
const profile = !!process.env.PROFILE;
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${port}/test/latency/flows.html?mock&turns=${turns}&resident`);
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
    return [...list.querySelectorAll<HTMLElement>("[data-tick]")].map((t) => t.getBoundingClientRect()).filter((r) => r.height > 0 && r.top >= box.top + 32 && r.bottom <= box.bottom - 32).map((r) => ({ x: r.left + 8, y: r.top + 5 }));
  });
  const mode = process.env.MODE ?? "";
  if (mode) console.log("mode", mode, "deleted", await page.evaluate((mode) => {
    let n = 0;
    const want = (sel: string) => mode === "nohas" ? sel.includes(":has(") : mode === "nohas-main" ? sel.includes(":has(") && sel.includes("acpmux-main") : mode === "nohas-nonsubject" ? /:has\([^)]*\)[^,{]*[ >~+]/.test(sel) : mode === "nohas-hover" ? /:has\([^{]*:(hover|focus)/.test(sel) : mode === "nohover-not" ? sel.includes(":not(:hover)") : mode === "nowhere-star" ? sel.includes(":where(button") : false;
    const walk = (list: CSSRuleList) => { for (let i = list.length - 1; i >= 0; i--) { const r = list[i] as any; if (r.cssRules && !(r instanceof CSSStyleRule)) walk(r.cssRules); else if (r.selectorText && want(r.selectorText)) { (r.parentRule ?? r.parentStyleSheet).deleteRule(i); n++; } } };
    for (const sheet of [...document.styleSheets]) { try { walk(sheet.cssRules); } catch {} }
    return n;
  }, mode));
  console.log("ticks", ticks.length, "dom elements", await page.evaluate(() => document.querySelectorAll("*").length));
  const cdp = await context.newCDPSession(page);
  const events: any[] = [];
  cdp.on("Tracing.dataCollected", (e: any) => events.push(...e.value));
  const done = new Promise((r) => cdp.once("Tracing.tracingComplete", r));
  if (profile) { await cdp.send("Profiler.enable"); await cdp.send("Profiler.setSamplingInterval", { interval: 200 }); await cdp.send("Profiler.start"); }
  await cdp.send("Tracing.start", { categories: "devtools.timeline,disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.invalidationTracking,disabled-by-default-devtools.timeline.stack,blink,v8.execute", transferMode: "ReportEvents" });
  for (const t of ticks.slice(0, 40)) {
    await page.mouse.move(t.x, t.y);
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0))));
  }
  await cdp.send("Tracing.end");
  if (profile) { const { profile: prof } = (await cdp.send("Profiler.stop")) as any; const self = new Map<string, number>(); const dt = new Map<number, number>(); prof.samples.forEach((id: number, i: number) => dt.set(id, (dt.get(id) ?? 0) + (prof.timeDeltas[i] ?? 0))); for (const n of prof.nodes) { const k = `${n.callFrame.functionName || "(anon)"} ${n.callFrame.url.split("/").pop()}:${n.callFrame.lineNumber}`; self.set(k, (self.get(k) ?? 0) + (dt.get(n.id) ?? 0) / 1000); } console.log("cpu self", [...self].sort((a, b) => b[1] - a[1]).slice(0, 30).map(([k, v]) => `${v.toFixed(1)}ms ${k}`).join("\n")); }
  await done;
  const main = events.filter((e) => e.name === "UpdateLayoutTree");
  const pid = main[0]?.pid, tid = main[0]?.tid;
  const onMain = events.filter((e) => e.pid === pid && e.tid === tid && e.ph === "X");
  const by = new Map<string, { n: number; ms: number }>();
  for (const e of onMain) { const v = by.get(e.name) ?? { n: 0, ms: 0 }; v.n++; v.ms += (e.dur ?? 0) / 1000; by.set(e.name, v); }
  const ult = onMain.filter((e) => e.name === "UpdateLayoutTree");
  const big = ult.filter((e) => (e.args?.elementCount ?? 0) > 300);
  console.log("SUMMARY", JSON.stringify({ mode: process.env.MODE ?? "", turns, recalcMs: +(ult.reduce((a, e) => a + (e.dur ?? 0), 0) / 1000).toFixed(1), layoutMs: +(onMain.filter((e) => e.name === "Layout").reduce((a, e) => a + (e.dur ?? 0), 0) / 1000).toFixed(1), roMs: +(onMain.filter((e) => e.name === "LocalFrameView::NotifyResizeObservers").reduce((a, e) => a + (e.dur ?? 0), 0) / 1000).toFixed(1), bigRecalcs: big.length, maxElements: Math.max(0, ...ult.map((e) => e.args?.elementCount ?? 0)) }));
  if (!process.env.BRIEF) {
  console.log("top events", [...by].sort((a, b) => b[1].ms - a[1].ms).slice(0, 25).map(([k, v]) => `${k} n=${v.n} ${v.ms.toFixed(1)}ms`).join("\n"));
  console.log("UpdateLayoutTree elementCount", ult.map((e) => e.args?.elementCount ?? e.args?.data?.elementCount).slice(0, 60).join(","));
  const inv = events.filter((e) => /Invalidation/.test(e.name));
  const reasons = new Map<string, number>();
  for (const e of inv) { const d = e.args?.data ?? {}; const k = `${e.name} | ${d.reason ?? ""} | ${d.selectors?.map((s: any) => s.selector).join(" ; ") ?? ""} | ${d.invalidationList?.map((s: any) => JSON.stringify(s)).join(" ") ?? ""} | ${d.nodeName ?? ""}`.slice(0, 1500); reasons.set(k, (reasons.get(k) ?? 0) + 1); }
  console.log("invalidations", [...reasons].sort((a, b) => b[1] - a[1]).slice(0, 30).map(([k, n]) => `${n}x ${k}`).join("\n"));
  // stacks of forced recalcs
  const forced = onMain.filter((e) => (e.name === 'UpdateLayoutTree' || e.name === 'Layout') && e.args?.beginData?.stackTrace).map((e) => `${e.name} n=${e.args?.elementCount ?? e.args?.beginData?.dirtyObjects ?? ''} ` + e.args.beginData.stackTrace.slice(0, 4).map((f: any) => `${f.functionName}@${f.url?.split("/").pop()}:${f.lineNumber}`).join(" < "));
  const fm = new Map<string, number>(); for (const f of forced) fm.set(f, (fm.get(f) ?? 0) + 1);
  console.log("forced recalcs", [...fm].sort((a, b) => b[1] - a[1]).slice(0, 15).map(([k, n]) => `${n}x ${k}`).join("\n"));
  }
} finally {
  await browser.close(); server.kill(); fs.rmSync(out, { recursive: true, force: true });
}
