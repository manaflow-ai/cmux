import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../webviews/test/support/galleryFrame";
const { createServer } = await import("vite");
const vite = await createServer({ configFile: path.resolve(import.meta.dir, "../webviews/vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const browser = await chromium.launch({ headless: true });
const entry = "agent-pane.since-divider";
await warmGalleryFrame(vite, entry, { browser, params: { variant: "line-working" } });
const port = (vite.httpServer!.address() as { port: number }).port;
const page = await browser.newPage({ viewport: { width: 640, height: 200 }, deviceScaleFactor: 2, reducedMotion: "reduce" });
for (const v of ["line-working", "line-worked"]) {
  await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: v })}`);
  await page.locator(".cv-worked").first().waitFor();
  await page.waitForTimeout(500);
  const sizes = await page.evaluate(() => ({ worked: getComputedStyle(document.querySelector(".cv-worked")!).fontSize, tag: getComputedStyle(document.querySelector(".cv-since__tag")!).fontSize }));
  console.log("SIZES", v, JSON.stringify(sizes));
  await page.screenshot({ path: path.resolve(import.meta.dir, `../proof-${v}.png`) });
}
await browser.close(); await vite.close();
