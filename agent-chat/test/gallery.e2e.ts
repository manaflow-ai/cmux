const port = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);
const base = `http://127.0.0.1:${port}`;

const page = await fetch(`${base}/gallery`);
if (!page.ok) throw new Error(`/gallery returned ${page.status}`);
const html = await page.text();
if (!html.includes('<div id="root"></div>')) throw new Error("/gallery did not return the app shell");
if (!html.includes('/gallery.js')) throw new Error("/gallery shell did not load gallery.js");

const galleryBundle = await fetch(`${base}/gallery.js`);
if (!galleryBundle.ok) throw new Error(`/gallery.js returned ${galleryBundle.status}`);
const galleryJs = await galleryBundle.text();
if (!galleryJs.includes("Agent Chat Gallery")) throw new Error("gallery bundle did not contain the gallery marker");

const appBundle = await fetch(`${base}/app.js`);
if (!appBundle.ok) throw new Error(`/app.js returned ${appBundle.status}`);
const appJs = await appBundle.text();
if (appJs.includes("Agent Chat Gallery")) throw new Error("app bundle still contains the gallery marker");

console.log("gallery smoke: OK");

export {};
