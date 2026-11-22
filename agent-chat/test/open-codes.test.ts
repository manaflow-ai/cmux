// One-time open codes (cx-e3l1): `cmux open` puts a URL in argv, so
// cmux-chat opens `/o/<code>` instead of the tokened URL. A code is used
// once, expires in 60 s, is stored only as a hash, and redirects only to a
// page route of this server.
import { expect, test } from "bun:test";
import { OpenCodes } from "../open-codes";

function clock(start = 1_000_000) {
  let now = start;
  return { now: () => now, advance: (ms: number) => { now += ms; } };
}

test("a code redeems once, then never again", () => {
  const codes = new OpenCodes();
  const code = codes.issue("/s/abc12345");
  expect(code).not.toBeNull();
  expect(codes.redeem(code!)).toBe("/s/abc12345");
  expect(codes.redeem(code!)).toBeNull();
});

test("an expired code is refused and forgotten", () => {
  const c = clock();
  const codes = new OpenCodes(c.now);
  const code = codes.issue("/")!;
  c.advance(60_001);
  expect(codes.redeem(code)).toBeNull();
  expect(codes.size).toBe(0);
});

test("an unknown code is refused", () => {
  const codes = new OpenCodes();
  codes.issue("/");
  expect(codes.redeem("x".repeat(43))).toBeNull();
  expect(codes.redeem("")).toBeNull();
});

test("codes are stored only as hashes", () => {
  const codes = new OpenCodes();
  const code = codes.issue("/gallery")!;
  expect(JSON.stringify([...codes.storedKeysForTest()])).not.toContain(code);
});

test("at most 16 codes are live; the oldest goes first", () => {
  const codes = new OpenCodes();
  const first = codes.issue("/")!;
  for (let i = 0; i < 16; i++) codes.issue("/");
  expect(codes.size).toBe(16);
  expect(codes.redeem(first)).toBeNull();
});

test("only page routes of this server are targets (no open redirect)", () => {
  const codes = new OpenCodes();
  for (const ok of ["/", "/s/abc12345", "/terminal/0123abcd-ef01", "/gallery", "/s/abc12345?transparent=1"]) {
    expect({ ok, code: codes.issue(ok) === null }).toEqual({ ok, code: false });
  }
  for (const bad of ["//evil.example/", "/\\evil.example", "https://evil.example/", "evil", "/api/sessions", "/o/abc",
    "/s/../api/theme", "/s/abc%2F..", "/s/abc\nLocation: x", "/%2Fevil.example", "/s/abc#x", ""]) {
    expect({ bad, refused: codes.issue(bad) === null }).toEqual({ bad, refused: true });
  }
});
