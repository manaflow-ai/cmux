import { URL } from "node:url";

import { extractMorphInstanceInfo } from "@cmux/shared";

export type ProxyConfig = {
  scheme: "socks5";
  host: string;
  port: number;
  bypassRules: string;
};

export const DEFAULT_PROXY_BYPASS = "cmux.local,cmux.localhost";
export const SING_BOX_PROXY_PORT = 39384;

export type ProxyRoutingResult = {
  proxyConfig: ProxyConfig | null;
  morphId: string | null;
  navigationUrl: string | null;
  displayUrl: string | null;
};

export function deriveMorphDetails(
  rawUrl: string | null | undefined,
): ProxyRoutingResult {
  if (!rawUrl) {
    return {
      proxyConfig: null,
      morphId: null,
      navigationUrl: null,
      displayUrl: null,
    };
  }

  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return {
      proxyConfig: null,
      morphId: null,
      navigationUrl: rawUrl,
      displayUrl: rawUrl,
    };
  }

  try {
    const info = extractMorphInstanceInfo(parsed);
    if (!info || !info.morphId || info.port === null) {
      return {
        proxyConfig: null,
        morphId: null,
        navigationUrl: rawUrl,
        displayUrl: rawUrl,
      };
    }

    const morphId = info.morphId;
    const host = `port-${SING_BOX_PROXY_PORT}-morphvm-${morphId}.http.cloud.morph.so`;
    const navigation = new URL(parsed.toString());
    navigation.hostname = "localhost";
    navigation.port = String(info.port);
    if (navigation.protocol === "https:") {
      navigation.protocol = "http:";
    } else if (navigation.protocol === "wss:") {
      navigation.protocol = "ws:";
    }

    const display = new URL(navigation.toString());
    display.hostname = "localhost";

    return {
      morphId,
      navigationUrl: navigation.toString(),
      displayUrl: display.toString(),
      proxyConfig: {
        scheme: "socks5",
        host,
        port: SING_BOX_PROXY_PORT,
        bypassRules: DEFAULT_PROXY_BYPASS,
      },
    };
  } catch {
    return {
      proxyConfig: null,
      morphId: null,
      navigationUrl: rawUrl,
      displayUrl: rawUrl,
    };
  }
}

