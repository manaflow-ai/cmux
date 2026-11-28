// Summarize bench results: node summarize.mjs out/results.json  -> markdown tables.
import fs from "node:fs";
const r = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const q = (a, p) => { const s = a.filter(Number.isFinite).sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : NaN; };
const f = x => Number.isFinite(x) ? x.toFixed(1) : "-";
console.log(`Chromium ${r.ua}, headless=${r.headless}, ${r.when}\n`);
console.log("| variant | switches | handler p50/p95 ms | first frame p50/p95 ms | new content 50% p50/p95 ms | 90% p50/p95 ms | fully clear p50 ms | dropped frames (total / switches with any) | max gap p95 ms | fully clear after a wheel at 30 ms, p95 |");
console.log("|---|---|---|---|---|---|---|---|---|---|");
for (const [v, s] of Object.entries(r.switches)) {
  const c = r.cancel[v];
  // Every second switch of the cancel run got a wheel 30 ms in; when was the new page fully clear?
  const cancelClear = c.switches.filter(x => x.cancelledAt).map(x => x.t100);
  const pair = k => `${f(q(s.map(x => x[k]), .5))} / ${f(q(s.map(x => x[k]), .95))}`;
  console.log(`| ${v} | ${s.length} | ${pair("handlerMs")} | ${pair("firstFrameMs")} | ${pair("t50")} | ${pair("t90")} | ${f(q(s.map(x => x.t100), .5))} | ${s.reduce((n, x) => n + x.dropped, 0)} / ${s.filter(x => x.dropped).length} | ${f(q(s.map(x => x.maxGapMs), .95))} | ${f(q(cancelClear, .95))} ms (${c.cancels.length} cancelled overlays) |`);
}
// light->dark vs dark->light vs same-luminance for the overlay variants.
console.log("\n| variant | big jumps (dL>0.5) n | 90% p50 ms | small jumps n | 90% p50 ms |");
console.log("|---|---|---|---|---|");
for (const [v, s] of Object.entries(r.switches)) {
  const big = s.filter(x => x.dL > 0.5), small = s.filter(x => x.dL <= 0.5);
  console.log(`| ${v} | ${big.length} | ${f(q(big.map(x => x.t90), .5))} | ${small.length} | ${f(q(small.map(x => x.t90), .5))} |`);
}
console.log("\n| View Transition mode | nav | runs | ran a transition | FCP p50 ms | reveal p50 ms | finished-reveal p50 ms | max frame gap p95 ms |");
console.log("|---|---|---|---|---|---|---|---|");
for (const [m, runs] of Object.entries(r.vt)) for (const cross of [false, true]) {
  const s = runs.filter(x => x.cross === cross);
  console.log(`| ${m} | ${cross ? "cross-origin" : "same-origin"} | ${s.length} | ${s.filter(x => x.hadTransition).length} | ${f(q(s.map(x => x.fcp), .5))} | ${f(q(s.map(x => x.reveal), .5))} | ${f(q(s.map(x => x.finished ? x.finished - x.reveal : NaN), .5))} | ${f(q(s.map(x => x.maxGap), .95))} |`);
}
