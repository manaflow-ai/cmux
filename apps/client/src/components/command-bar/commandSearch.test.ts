import { describe, expect, it } from "vitest";

import { filterCommandItems } from "./commandSearch";

const makeItem = (value: string, searchText: string) => ({
  value,
  searchText,
});

describe("filterCommandItems", () => {
  it("skips obvious non-matches for multi-word queries before fuzzy scoring", () => {
    const items = [
      makeItem("diff", "Read diff with main"),
      makeItem("dashboard", "Open dashboard"),
      makeItem("logs", "View logs for selected runs"),
    ];

    const result = filterCommandItems("read diff with main", items);

    expect(result.map((item) => item.value)).toEqual(["diff"]);
  });

  it("keeps fuzzy matching behavior for single-token shorthands", () => {
    const items = [
      makeItem("diff", "Read diff with main"),
      makeItem("dashboard", "Open dashboard"),
    ];

    const result = filterCommandItems("rdm", items);

    expect(result[0]?.value).toBe("diff");
  });

  it("orders multi-word matches by proximity without invoking fuzzy matching", () => {
    const items = [
      makeItem("exact-order", "Read diff with main branch"),
      makeItem(
        "scattered",
        "main review output read pending diff with branch copy",
      ),
    ];

    const result = filterCommandItems("read diff with main", items);

    expect(result.map((item) => item.value)).toEqual([
      "exact-order",
      "scattered",
    ]);
  });

  it("respects the provided result limit for non-empty queries", () => {
    const items = Array.from({ length: 20 }, (_, index) =>
      makeItem(`item-${index}`, `Item number ${index}`),
    );

    const result = filterCommandItems("item", items, { limit: 5 });

    expect(result).toHaveLength(5);
  });

  it("ignores the result limit for empty queries", () => {
    const items = Array.from({ length: 10 }, (_, index) =>
      makeItem(`item-${index}`, `Item number ${index}`),
    );

    const result = filterCommandItems("", items, { limit: 3 });

    expect(result).toHaveLength(items.length);
  });
});
