// CDP-side stress: hammers every page with navigation, typing, mouse
// clicking, scrolling, and drag events while the app (launched with
// CEFDEMO_STRESS=1) simultaneously churns window size, profile switching, and
// DevTools dock/undock cycles. Passes if, after the storm, every page still
// evaluates JavaScript and the process never crashed.
// Run: bun Demo/scripts/stress.mjs [port] [seconds]
const port = Number(process.argv[2] ?? 19230);
const seconds = Number(process.argv[3] ?? 45);
const deadline = Date.now() + seconds * 1000;

const NAV_URLS = [
  "https://example.com/?stress=a",
  "https://example.org/?stress=b",
  "https://httpbin.org/forms/post",
  "data:text/html,<input id=t autofocus><div id=d draggable=true style='width:80px;height:80px;background:teal'>drag</div><div style='height:3000px'>tall</div>",
];

async function pages() {
  const res = await fetch(`http://127.0.0.1:${port}/json`);
  return (await res.json()).filter(
    (t) => t.type === "page" && !t.url.startsWith("devtools://") && !t.url.includes("/devtools/")
  );
}

function connect(target) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    let id = 0;
    const pending = new Map();
    const failAll = (why) => {
      for (const { rej2 } of pending.values()) rej2(new Error(why));
      pending.clear();
    };
    const openTimer = setTimeout(() => reject(new Error("ws open timeout")), 5000);
    ws.addEventListener("open", () => {
      clearTimeout(openTimer);
      resolve({
        ws,
        call(method, params = {}) {
          return new Promise((res2, rej2) => {
            if (ws.readyState !== WebSocket.OPEN) return rej2(new Error("ws closed"));
            const mid = ++id;
            const timer = setTimeout(() => {
              pending.delete(mid);
              rej2(new Error(`rpc timeout: ${method}`));
            }, 5000);
            pending.set(mid, { res2: (v) => { clearTimeout(timer); res2(v); }, rej2: (e) => { clearTimeout(timer); rej2(e); } });
            ws.send(JSON.stringify({ id: mid, method, params }));
          });
        },
      });
    });
    ws.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && pending.has(msg.id)) {
        const { res2, rej2 } = pending.get(msg.id);
        pending.delete(msg.id);
        msg.error ? rej2(new Error(JSON.stringify(msg.error))) : res2(msg.result);
      }
    });
    ws.addEventListener("close", () => failAll("ws closed"));
    ws.addEventListener("error", (e) => {
      clearTimeout(openTimer);
      failAll("ws error");
      reject(new Error("ws error"));
    });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (n) => Math.floor(Math.random() * n);

async function stressPage(target, label) {
  let conn;
  try {
    conn = await connect(target);
  } catch {
    return; // page went away (profile switch, navigation); fine
  }
  const { call, ws } = conn;
  try {
    await call("Page.enable").catch(() => {});
    let iterations = 0;
    let consecutiveFailures = 0;
    while (Date.now() < deadline) {
      if (ws.readyState !== WebSocket.OPEN || consecutiveFailures > 10) {
        console.log(`page[${label}] connection lost after ${iterations} iterations (expected during churn)`);
        break;
      }
      iterations++;
      const action = rand(6);
      try {
        switch (action) {
          case 0:
            await call("Page.navigate", { url: NAV_URLS[rand(NAV_URLS.length)] });
            await sleep(400);
            break;
          case 1: // typing burst
            for (const ch of "cefkit stress " + iterations) {
              await call("Input.dispatchKeyEvent", { type: "keyDown", text: ch });
              await call("Input.dispatchKeyEvent", { type: "keyUp" });
            }
            break;
          case 2: // click storm
            for (let i = 0; i < 5; i++) {
              const x = 20 + rand(600);
              const y = 20 + rand(400);
              await call("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
              await call("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
            }
            break;
          case 3: // scroll storm
            for (let i = 0; i < 10; i++) {
              await call("Input.dispatchMouseEvent", {
                type: "mouseWheel", x: 300, y: 300, deltaX: 0, deltaY: rand(2) ? 240 : -240,
              });
            }
            break;
          case 4: // drag gesture
            await call("Input.dispatchDragEvent", {
              type: "dragEnter", x: 60, y: 60,
              data: { items: [{ mimeType: "text/plain", data: "stress" }], dragOperationsMask: 1 },
            }).catch(() => {});
            await call("Input.dispatchDragEvent", {
              type: "dragOver", x: 300, y: 300,
              data: { items: [{ mimeType: "text/plain", data: "stress" }], dragOperationsMask: 1 },
            }).catch(() => {});
            await call("Input.dispatchDragEvent", {
              type: "drop", x: 300, y: 300,
              data: { items: [{ mimeType: "text/plain", data: "stress" }], dragOperationsMask: 1 },
            }).catch(() => {});
            break;
          case 5: // JS churn: DOM allocation + history API
            await call("Runtime.evaluate", {
              expression: `for (let i=0;i<200;i++){const d=document.createElement('div');d.textContent=i;document.body?.appendChild(d);} history.pushState({},'','?s=${iterations}'); document.title='stress ${label} ${iterations}'`,
            });
            break;
        }
        consecutiveFailures = 0;
      } catch {
        // Individual dispatch failures during navigation races are expected;
        // the pass/fail signal is the final responsiveness check.
        consecutiveFailures++;
      }
      await sleep(30);
    }
    console.log(`page[${label}] iterations: ${iterations}`);
  } finally {
    ws.close();
  }
}

console.log(`stressing for ${seconds}s against port ${port}...`);
const initial = await pages();
if (initial.length === 0) {
  console.error("FAIL: no pages to stress");
  process.exit(1);
}

// Watchdog: never hang past the deadline no matter what a socket does.
const watchdog = setTimeout(() => {
  console.error("watchdog: stress workers wedged, proceeding to final check");
}, (seconds + 20) * 1000);

// Sample target list during the run; the app-side stress loop cycles DevTools
// docked/window modes, which must show up as devtools:// targets.
let devtoolsSightings = 0;
const sampler = setInterval(async () => {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json`);
    const all = await res.json();
    if (all.some((t) => t.url.startsWith("devtools://") || t.url.includes("/devtools/"))) devtoolsSightings++;
  } catch {}
}, 3000);

await Promise.race([
  Promise.all(initial.map((t, i) => stressPage(t, i))),
  sleep((seconds + 15) * 1000),
]);
clearTimeout(watchdog);
clearInterval(sampler);
console.log(`devtools target sightings during run: ${devtoolsSightings}`);

// Give the app a moment to settle, then the verdict: every page answers.
await sleep(1500);
let failed = false;
const finalPages = await pages().catch(() => null);
if (!finalPages || finalPages.length === 0) {
  console.error("FAIL: browser process unreachable after stress");
  process.exit(1);
}
for (const [i, t] of finalPages.entries()) {
  try {
    const { call, ws } = await connect(t);
    const r = await call("Runtime.evaluate", { expression: "1+1", returnByValue: true });
    ws.close();
    const ok = r.result.value === 2;
    console.log(`${ok ? "PASS" : "FAIL"}: page[${i}] responsive (${t.url.slice(0, 60)})`);
    if (!ok) failed = true;
  } catch (e) {
    console.log(`FAIL: page[${i}] unreachable: ${e}`);
    failed = true;
  }
}
console.log(failed ? "STRESS FAILED" : "STRESS PASSED");
process.exit(failed ? 1 : 0);
