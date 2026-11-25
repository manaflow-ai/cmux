// Run with: node --test cmux-tui/crates/acpmux/skills/cmux-rich-output/tests/deck.test.mjs
// The deck template's pure logic (the block between `deck-logic:start` and `deck-logic:end` in
// templates/deck.html): the slide from a URL hash, the pace against data-seconds, the script's
// sentences and the caption for a moment.
import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";

const html = fs.readFileSync(new URL("../templates/deck.html", import.meta.url), "utf8");
const block = html.match(/\/\/ deck-logic:start\n([\s\S]*?)\/\/ deck-logic:end/);
assert.ok(block, "templates/deck.html has a deck-logic block");
const deckLogic = new Function(`${block[1]}; return deckLogic;`)();

test("the slide comes from the hash, clamped, and the first slide otherwise", () => {
  assert.equal(deckLogic.slideFromHash("#3", 5), 2);
  assert.equal(deckLogic.slideFromHash("3", 5), 2);
  assert.equal(deckLogic.slideFromHash("#9", 5), 4);
  for (const hash of ["", "#", "#0", "#-2", "#abc", "#2.5", undefined]) assert.equal(deckLogic.slideFromHash(hash, 5), 0, String(hash));
});

test("the timed run ends at the first appendix-start", () => {
  assert.equal(deckLogic.timedCount([false, false, true, false]), 2);
  assert.equal(deckLogic.timedCount([false, false]), 2);
  assert.equal(deckLogic.timedCount([true, false]), 0);
});

test("pace: arriving early is ahead, dwelling past the budget is behind", () => {
  const budgets = [20, 40, 30, 0];
  // On slide 2 (index 1) at 10 s total, 2 s in: planned 20 + 2 = 22, so 12 s ahead.
  let p = deckLogic.pace(budgets, 3, 1, 10, 2);
  assert.deepEqual([p.planned, p.appendix, p.delta, p.budget, p.left], [90, false, -12, 40, 38]);
  assert.equal(deckLogic.paceWord(p.delta), "ahead");
  // Arrived on time (20 s) and stayed 50 s on a 40 s slide: 10 s behind, 10 s over.
  p = deckLogic.pace(budgets, 3, 1, 70, 50);
  assert.deepEqual([p.delta, p.left], [10, -10]);
  assert.equal(deckLogic.paceWord(p.delta), "on");
  assert.equal(deckLogic.paceWord(11), "behind");
  // Exactly on plan.
  assert.equal(deckLogic.pace(budgets, 3, 2, 75, 15).delta, 0);
});

test("pace: appendix slides are untimed and compare against the whole planned run", () => {
  const p = deckLogic.pace([20, 40, 30, 99], 3, 3, 100, 5);
  assert.equal(p.appendix, true);
  assert.equal(p.planned, 90);
  assert.equal(p.delta, 10);
});

test("sentences split the script and keep their punctuation", () => {
  assert.deepEqual(deckLogic.sentences("  One.  Two words here!\nThree? Four"), ["One.", "Two words here!", "Three?", "Four"]);
  assert.deepEqual(deckLogic.sentences('He said "go." Then left.'), ['He said "go."', "Then left."]);
  assert.deepEqual(deckLogic.sentences(""), []);
  assert.deepEqual(deckLogic.sentences(undefined), []);
});

test("the caption follows the slide's budget, spread by sentence length", () => {
  const s = ["aaaaaaaaaa", "bbbbbbbbbb", "cccccccccccccccccccc"]; // 10, 10, 20 characters
  assert.equal(deckLogic.captionAt(s, 0, 40), 0);
  assert.equal(deckLogic.captionAt(s, 9.9, 40), 0);
  assert.equal(deckLogic.captionAt(s, 10, 40), 1);
  assert.equal(deckLogic.captionAt(s, 25, 40), 2);
  assert.equal(deckLogic.captionAt(s, 400, 40), 2);
  // No budget: 15 characters a second.
  assert.equal(deckLogic.captionAt(s, 1, 0), 1);
  assert.equal(deckLogic.captionAt([], 3, 10), -1);
});

test("clock formats seconds as m:ss, h:mm:ss past an hour, and signs negatives", () => {
  assert.equal(deckLogic.clock(0), "0:00");
  assert.equal(deckLogic.clock(65.4), "1:05");
  assert.equal(deckLogic.clock(-12), "-0:12");
  assert.equal(deckLogic.clock(3725), "1:02:05");
});

test("the signature tells two versions of a deck apart", () => {
  assert.equal(deckLogic.signature("<section>a</section>"), deckLogic.signature("<section>a</section>"));
  assert.notEqual(deckLogic.signature("<section>a</section>"), deckLogic.signature("<section>b</section>"));
});

test("the template's example deck follows the contract: data-seconds, notes, an appendix", () => {
  const sections = [...html.matchAll(/<section([^>]*)>([\s\S]*?)<\/section>/g)];
  const appendix = sections.findIndex(([, attrs]) => /appendix-start/.test(attrs));
  assert.ok(appendix > 0, "an appendix-start slide after the timed run");
  for (const [, attrs, body] of sections.slice(0, appendix)) {
    assert.match(attrs, /data-seconds="\d+"/);
    assert.match(body, /<aside class="notes">/);
  }
  // The runtime stays the file's last element.
  assert.match(html, /<\/script>\s*<\/body>\s*<\/html>\s*$/);
});

test("budgets: a backup slide (data-skip) is passed over, so the pace never counts it", () => {
  const budgets = deckLogic.budgets(["20", undefined, "40", "abc", "-5", "30"], [false, false, true, false, false, false]);
  assert.deepEqual(budgets, [20, 0, 0, 0, 0, 30]);
  // The planned run (5 timed slides, the appendix from index 5) leaves the skipped 40 s out.
  assert.equal(deckLogic.pace(budgets, 5, 0, 0, 0).planned, 20);
  assert.equal(deckLogic.pace(budgets, 5, 5, 25, 0).appendix, true);
});

test("spoken: the time spoken stands still while paused", () => {
  assert.equal(deckLogic.spoken(null, null, 5000), 0);
  assert.equal(deckLogic.spoken(1000, null, 6000), 5);
  assert.equal(deckLogic.spoken(1000, 4000, 9000), 3);
  assert.equal(deckLogic.spoken(9000, null, 1000), 0);
});

test("the runtime keeps Present with speaker notes, backup slides and one channel", () => {
  const runtime = html.slice(html.lastIndexOf("<script>"));
  for (const needle of ["Present with speaker notes", "data-skip", "cmux-deck-presenter", "deck-console", "Audience window", "Laser", "Captions"]) assert.ok(runtime.includes(needle), needle);
  assert.equal((runtime.match(/new BroadcastChannel\(/g) || []).length, 1, "one channel for every window of a deck");
  assert.equal((html.match(/<script/g) || []).length, 1, "the runtime is the only script");
});
