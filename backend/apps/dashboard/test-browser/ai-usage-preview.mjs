// Run: start the console dev server (bun run dev), then `node test-browser/ai-usage-preview.mjs http://127.0.0.1:3010`
// with playwright installed (a Freestyle webviews VM; never on the laptop). Writes screenshots to $ARTIFACTS_DIR.
// Browser check of the AI usage preview route (cx-y79zh.1): screenshots of both variants in each state,
// and the hover/edit behavior: row actions hidden at rest, shown on hover; Edit -> field -> Save updates the limit.
import { chromium } from "playwright"
const base = process.argv[2] ?? "http://127.0.0.1:3010"
const out = process.env.ARTIFACTS_DIR ?? "/tmp"
const browser = await chromium.launch()
const results = []
const check = (name, ok, detail = "") => { results.push({ name, ok, detail }); console.log(`${ok ? "PASS" : "FAIL"} ${name} ${detail}`) }
for (const scheme of ["light", "dark"]) {
  const page = await browser.newPage({ viewport: { width: 1600, height: 1100 }, colorScheme: scheme })
  for (const state of ["billed-team", "billed-over", "unbilled-near", "stopped", "no-line"]) {
    await page.goto(`${base}/preview/ai-usage?state=${state}`, { waitUntil: "networkidle" })
    await page.waitForSelector(".aiu")
    await page.screenshot({ path: `${out}/ai-usage-${state}-${scheme}.png`, fullPage: true })
  }
  await page.close()
}
const page = await browser.newPage({ viewport: { width: 900, height: 900 } })
const errors = []
page.on("pageerror", (e) => errors.push(String(e)))
for (const variant of ["meter", "ledger"]) {
  await page.goto(`${base}/preview/ai-usage?state=billed-team&variant=${variant}`, { waitUntil: "networkidle" })
  const row = variant === "meter" ? page.locator(".aiu-member").nth(2) : page.locator(".aiu-table tbody tr").nth(2)
  const action = row.locator(".aiu-actions button").first()
  check(`${variant}: actions hidden at rest`, !(await action.isVisible()))
  await row.hover()
  check(`${variant}: actions shown on hover`, await action.isVisible())
  await page.screenshot({ path: `${out}/ai-usage-${variant}-hover.png` })
  await action.click()
  const input = row.locator("input")
  check(`${variant}: edit opens a field`, await input.isVisible())
  await input.fill("75")
  await row.locator("button[type=submit]").click()
  await page.waitForFunction((v) => !document.querySelector(`.aiu input`), variant)
  const text = await row.innerText()
  check(`${variant}: saved limit shows`, /\$75/.test(text) && /Personal limit/.test(text), JSON.stringify(text.slice(0, 120)))
  // Keyboard focus reveals the actions too.
  await page.keyboard.press("Tab")
  const def = page.locator(".aiu-row-hover").first()
  await def.focus()
  check(`${variant}: focus reveals default actions`, await def.locator(".aiu-actions button").first().isVisible())
  await page.screenshot({ path: `${out}/ai-usage-${variant}-edited.png` })
}
check("no page errors", errors.length === 0, errors.join(" | "))
await browser.close()
process.exit(results.every((r) => r.ok) ? 0 : 1)
