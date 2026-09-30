import { describe, expect, test } from "bun:test";

Object.defineProperty(globalThis, "location", {
  configurable: true,
  value: { pathname: "/" },
});

const { decodeFileDiffRequest, fileDiffCacheKey, foldEvent } = await import("../src/session");

describe("file diff cache", () => {
  test("keys diffs by files-changed revision and path", () => {
    const first = fileDiffCacheKey("1", "tracked.txt");
    const second = fileDiffCacheKey("2", "tracked.txt");

    expect(first).not.toBe(second);
    expect(decodeFileDiffRequest(second)).toEqual({ key: second, path: "tracked.txt" });
  });

  test("assigns a new revision to each files-changed block", () => {
    const first = foldEvent([], {
      kind: "files-changed",
      files: [{ path: "tracked.txt", adds: 1, dels: 0, status: "modified" }],
    });
    const second = foldEvent(first, {
      kind: "files-changed",
      files: [{ path: "tracked.txt", adds: 2, dels: 0, status: "modified" }],
    });

    expect(first[first.length - 1]).toMatchObject({ kind: "files", revision: "1" });
    expect(second[second.length - 1]).toMatchObject({ kind: "files", revision: "2" });
  });
});
