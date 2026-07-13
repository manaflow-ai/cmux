// Automated proof over the Chrome DevTools Protocol that CEFKit's three
// claims hold in a running CEFDemo (launch with CEFDEMO_DEBUG_PORT=19230
// CEFDEMO_AUTOTEST=1):
//   1. one page per profile is rendering
//   2. document.cookie written in one profile is invisible to the others
//   3. the bundled test extension's content script injected its marker
// Run: bun Demo/scripts/verify.mjs [port]
const port = Number(process.argv[2] ?? 19230);

async function targets() {
  const res = await fetch(`http://127.0.0.1:${port}/json`);
  return (await res.json()).filter((t) => t.type === "page");
}

function rpc(ws, id, method, params = {}) {
  return new Promise((resolve, reject) => {
    const onMessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id === id) {
        ws.removeEventListener("message", onMessage);
        msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
      }
    };
    ws.addEventListener("message", onMessage);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

async function withPage(target, fn) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve);
    ws.addEventListener("error", reject);
  });
  try {
    let id = 0;
    return await fn((method, params) => rpc(ws, ++id, method, params));
  } finally {
    ws.close();
  }
}

const evalIn = (call, expression) =>
  call("Runtime.evaluate", { expression, returnByValue: true }).then((r) => r.result.value);

const pages = await targets();
const byProfile = {};
for (const t of pages) {
  const profile = new URL(t.url).searchParams.get("profile");
  if (profile) byProfile[profile] = t;
}
const names = Object.keys(byProfile).sort();
console.log(`pages: ${pages.length}, profiles: ${names.join(", ")}`);
if (names.length < 3) {
  console.error("FAIL: expected pages for default, work, personal");
  process.exit(1);
}

let failed = false;
const check = (ok, label) => {
  console.log(`${ok ? "PASS" : "FAIL"}: ${label}`);
  if (!ok) failed = true;
};

// Write a distinct cookie in each profile.
for (const name of names) {
  await withPage(byProfile[name], async (call) => {
    await evalIn(call, `document.cookie = "who=${name}; path=/"`);
  });
}

// Each profile must see exactly its own cookie.
for (const name of names) {
  const cookie = await withPage(byProfile[name], (call) => evalIn(call, "document.cookie"));
  const own = cookie.includes(`who=${name}`);
  const leaked = names.some((other) => other !== name && cookie.includes(`who=${other}`));
  check(own && !leaked, `profile "${name}" cookie isolation (saw: ${JSON.stringify(cookie)})`);
}

// Extension content script marker must be present.
for (const name of names) {
  const marker = await withPage(byProfile[name], (call) =>
    evalIn(call, "!!document.querySelector('#cefkit-ext-marker')")
  );
  check(marker === true, `profile "${name}" extension content script injected`);
}

// Screenshot for the humans.
const shot = await withPage(byProfile[names[0]], (call) => call("Page.captureScreenshot", {}));
const out = "/tmp/cefdemo-verify.png";
await import("node:fs/promises").then((fs) => fs.writeFile(out, Buffer.from(shot.data, "base64")));
console.log(`screenshot: ${out}`);

process.exit(failed ? 1 : 0);
