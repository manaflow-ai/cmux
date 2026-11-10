set -e
python3 scripts/cmux-next/gen-motion-scale.py --check
cd webviews
bun scripts/check-design-tokens.ts
bun test test/motion-scale.test.ts src/agent-session/acpmux/chatSwitch.test.ts src/ui/motion/motion.test.tsx test/spinner-period.test.ts test/session-info-motion.test.tsx test/session-info-fold-motion.test.tsx test/calm-motion.test.ts src/agent-session/acpmux/conversation src/agent-session/acpmux/header src/ui src/pages/home-messages > "$FAST_CHECKS_OUT/bun.log" 2>&1 || { grep -E "^\(fail\)|error:" "$FAST_CHECKS_OUT/bun.log" | head -40; tail -6 "$FAST_CHECKS_OUT/bun.log"; exit 1; }
tail -6 "$FAST_CHECKS_OUT/bun.log"
cat > /tmp/cap.mjs <<'JS'
import { chromium } from "playwright";
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1400, height: 900 } });
p.on("pageerror", e => console.log("pageerror", e.message));
await p.goto("file://" + process.argv[2]);
await p.waitForSelector("html[data-ready='1']");
await p.screenshot({ path: process.env.FAST_CHECKS_OUT + "/motion-ceiling-gallery.png", fullPage: true });
console.log("captured");
await b.close();
JS
cp /tmp/cap.mjs ./cap-tmp.mjs && bun ./cap-tmp.mjs "$PWD/../design/motion-ceiling-gallery.html"
