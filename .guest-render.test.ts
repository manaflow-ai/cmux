// Scratch render (not committed): guest-page.live variants, before/after the rail fix.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

setDefaultTimeout(240_000);
const { createServer } = await import("vite");
let vite: Awaited<ReturnType<typeof createServer>>;
let browser: Browser;
beforeAll(async () => {
  vite = await createServer({
    configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "guest-page.live", { browser, params: { variant: "view-only" } });
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});
for (const [variant, width, scheme] of [
  ["view-only", 760, "dark"],
  ["view-only", 760, "light"],
  ["view-only", 390, "dark"],
  ["working", 760, "dark"],
  ["asking", 760, "light"],
] as const)
  test(`${variant} ${width} ${scheme}`, async () => {
    const page = await browser.newPage({ viewport: { width, height: 720 }, deviceScaleFactor: 2 });
    const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame("guest-page.live", { variant, width, height: 720, colorScheme: scheme }));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.getByText("Fix the flaky upload retry test").first().waitFor();
    await page.waitForTimeout(500);
    const out = process.env.FAST_CHECKS_OUT ?? "/tmp";
    await page.screenshot({ path: `${out}/${process.env.LABEL}-${variant}-${width}-${scheme}.png` });
    const rails = await page.locator(".acpmux-minimap").count();
    console.log(`RAILS ${process.env.LABEL} ${variant} ${width} ${scheme}: ${rails}`);
    await page.close();
  });
