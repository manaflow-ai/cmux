import { describe, expect, it } from "vitest";

import {
  shouldUseIframePreflightProxy,
  shouldUseServerIframePreflight,
} from "./useIframePreflight";

describe("shouldUseIframePreflightProxy", () => {
  it("returns true for direct Morph cloud hosts", () => {
    expect(
      shouldUseIframePreflightProxy(
        "https://port-39379-morphvm-abc123.http.cloud.morph.so/",
      ),
    ).toBe(true);
  });

  it("returns true for cmux proxy hosts", () => {
    expect(
      shouldUseIframePreflightProxy(
        "https://cmux-abc123-base-39379.cmux.app/workspace",
      ),
    ).toBe(true);
  });

  it("returns true for cmux port hosts", () => {
    expect(
      shouldUseIframePreflightProxy(
        "https://port-39379-abc123.cmux.app/",
      ),
    ).toBe(true);
  });

  it("returns false for localhost targets", () => {
    expect(
      shouldUseIframePreflightProxy("http://localhost:9775/index.html"),
    ).toBe(false);
  });

  it("returns false for non-Morph remote hosts", () => {
    expect(shouldUseIframePreflightProxy("https://example.com")).toBe(false);
  });

  it("returns false for invalid URLs", () => {
    expect(shouldUseIframePreflightProxy("not-a-url")).toBe(false);
    expect(shouldUseIframePreflightProxy(null)).toBe(false);
    expect(shouldUseIframePreflightProxy(undefined)).toBe(false);
  });
});

describe("shouldUseServerIframePreflight", () => {
  it("returns true for localhost", () => {
    expect(
      shouldUseServerIframePreflight("http://localhost:3000/preview"),
    ).toBe(true);
  });

  it("returns true for loopback IPv4", () => {
    expect(
      shouldUseServerIframePreflight("http://127.0.0.1:8080/app"),
    ).toBe(true);
  });

  it("returns true for *.localhost", () => {
    expect(
      shouldUseServerIframePreflight(
        "http://preview.localhost:4173/workspace",
      ),
    ).toBe(true);
  });

  it("returns false for non-local hosts", () => {
    expect(shouldUseServerIframePreflight("https://example.com")).toBe(false);
  });

  it("returns false for invalid inputs", () => {
    expect(shouldUseServerIframePreflight(null)).toBe(false);
    expect(shouldUseServerIframePreflight(undefined)).toBe(false);
    expect(shouldUseServerIframePreflight("not-a-url")).toBe(false);
  });
});
