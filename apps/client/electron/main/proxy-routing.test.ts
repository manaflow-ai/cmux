import { describe, expect, it } from "vitest";

import {
  deriveMorphDetails,
  SING_BOX_PROXY_PORT,
} from "./proxy-routing";

describe("deriveMorphDetails", () => {
  it("returns nulls for empty input", () => {
    const result = deriveMorphDetails(null);
    expect(result.proxyConfig).toBeNull();
    expect(result.morphId).toBeNull();
    expect(result.navigationUrl).toBeNull();
    expect(result.displayUrl).toBeNull();
  });

  it("passes through non-morph URLs untouched", () => {
    const url = "https://example.com/foo";
    const result = deriveMorphDetails(url);
    expect(result.proxyConfig).toBeNull();
    expect(result.morphId).toBeNull();
    expect(result.navigationUrl).toBe(url);
    expect(result.displayUrl).toBe(url);
  });

  it("derives proxy routing for morph hosts", () => {
    const url =
      "https://port-39380-morphvm-abc123.http.cloud.morph.so/vnc.html?autoconnect=1";
    const result = deriveMorphDetails(url);

    expect(result.morphId).toBe("abc123");
    expect(result.navigationUrl).toBe("http://localhost:39380/vnc.html?autoconnect=1");
    expect(result.displayUrl).toBe("http://localhost:39380/vnc.html?autoconnect=1");
    expect(result.proxyConfig).not.toBeNull();
    expect(result.proxyConfig).toMatchObject({
      scheme: "socks5",
      host: `port-${SING_BOX_PROXY_PORT}-morphvm-abc123.http.cloud.morph.so`,
      port: SING_BOX_PROXY_PORT,
    });
  });
});

