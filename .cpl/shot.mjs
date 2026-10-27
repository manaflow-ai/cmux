// Screenshots of the Mobile Pairing page in the browser dev loop (`/mobile-pairing/?mock`): signed
// in, iPhone connections on, the host ready. Prints each PNG as base64 between markers.
import { chromium } from "playwright";
const [, , url, label] = process.argv;
const browser = await chromium.launch();
for (const scheme of ["light", "dark"]) {
  const page = await browser.newPage({ viewport: { width: 640, height: 720 }, colorScheme: scheme, deviceScaleFactor: 2 });
  await page.goto(url);
  await page.waitForSelector("[data-action=sign-in]", { timeout: 60000 });
  await page.click("[data-action=sign-in]");
  await page.waitForSelector("[data-action=allow]");
  await page.click("[data-action=allow]");
  await page.waitForSelector(".pairing-ready", { timeout: 10000 });
  await page.waitForTimeout(300);
  const png = await page.screenshot({ fullPage: true });
  console.log(`===PNG ${label}-${scheme} BEGIN===`);
  console.log(png.toString("base64"));
  console.log(`===PNG ${label}-${scheme} END===`);
  await page.close();
}
await browser.close();
