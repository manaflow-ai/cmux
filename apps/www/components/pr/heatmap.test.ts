import { describe, expect, it } from "vitest";
import { computeNewLineNumber, parseDiff } from "react-diff-view";

import { buildDiffHeatmap, parseReviewHeatmap } from "./heatmap";

const SAMPLE_DIFF = `
diff --git a/example.ts b/example.ts
index 1111111..2222222 100644
--- a/example.ts
+++ b/example.ts
@@ -1,3 +1,4 @@
 const a = 1;
-const b = 2;
-export const sum = a + b;
+const b = 3;
+const message = "heatmap";
+export const sum = a + b + Number(message.length);
`;

describe("parseReviewHeatmap", () => {
  it("parses nested codex payloads best-effort", () => {
    const parsed = parseReviewHeatmap({
      response: JSON.stringify({
        lines: [
          {
            line: "2",
            shouldBeReviewedScore: 0.3,
            shouldReviewWhy: "first pass",
            mostImportantCharacterIndex: 4,
          },
          {
            line: "2",
            shouldBeReviewedScore: 0.7,
            shouldReviewWhy: "updated score",
            mostImportantCharacterIndex: 6,
          },
          {
            line: 4,
            shouldBeReviewedScore: 0.92,
            shouldReviewWhy: "new export logic",
            mostImportantCharacterIndex: 120,
          },
          {
            line: "invalid",
            shouldBeReviewedScore: 1,
            shouldReviewWhy: "ignored",
            mostImportantCharacterIndex: 0,
          },
        ],
      }),
    });

    expect(parsed).toHaveLength(4);
    const numericEntries = parsed.filter((entry) => entry.lineNumber !== null);
    expect(numericEntries).toHaveLength(3);
    expect(parsed[0]?.lineNumber).toBe(2);
    expect(parsed[1]?.lineNumber).toBe(2);
    expect(parsed.some((entry) => entry.lineNumber === 4)).toBe(true);
    const fallbackEntry = parsed.find((entry) => entry.lineText === "invalid");
    expect(fallbackEntry?.lineNumber).toBeNull();
  });
});

describe("buildDiffHeatmap", () => {
  it("produces tiered classes and character highlights", () => {
    const files = parseDiff(SAMPLE_DIFF);
    const file = files[0] ?? null;
    expect(file).not.toBeNull();

    const review = parseReviewHeatmap({
      response: JSON.stringify({
        lines: [
          {
            line: "2",
            shouldBeReviewedScore: 0.3,
            shouldReviewWhy: "first pass",
            mostImportantCharacterIndex: 4,
          },
          {
            line: "2",
            shouldBeReviewedScore: 0.7,
            shouldReviewWhy: "updated score",
            mostImportantCharacterIndex: 6,
          },
          {
            line: 4,
            shouldBeReviewedScore: 0.92,
            shouldReviewWhy: "new export logic",
            mostImportantCharacterIndex: 120,
          },
        ],
      }),
    });

    const heatmap = buildDiffHeatmap(file, review);
    expect(heatmap).not.toBeNull();
    if (!heatmap) {
      return;
    }

    expect(heatmap.entries.get(2)?.score).toBeCloseTo(0.7, 5);
    expect(heatmap.lineClasses.get(2)).toBe("cmux-heatmap-tier-3");
    expect(heatmap.lineClasses.get(4)).toBe("cmux-heatmap-tier-4");

    const rangeForLine2 = heatmap.newRanges.find(
      (range) => range.lineNumber === 2
    );
    expect(rangeForLine2?.start).toBe(6);
    expect(rangeForLine2?.length).toBe(1);

    const rangeForLine4 = heatmap.newRanges.find(
      (range) => range.lineNumber === 4
    );
    expect(rangeForLine4).toBeDefined();
    if (!rangeForLine4) {
      return;
    }

    const lineFourChange = file!.hunks[0]?.changes.find(
      (change) => computeNewLineNumber(change) === 4
    );
    const expectedStart = Math.max(
      (lineFourChange?.content.length ?? 1) - 1,
      0
    );
    expect(rangeForLine4.start).toBe(expectedStart);
    expect(rangeForLine4.length).toBe(1);
  });
});
