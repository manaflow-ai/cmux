"use client";

import {
  useEffect,
  useMemo,
  useState,
  type AnchorHTMLAttributes,
} from "react";

import type { MacArchitecture, MacDownloadUrls } from "@/lib/releases";

type MacDownloadLinkProps = Omit<
  AnchorHTMLAttributes<HTMLAnchorElement>,
  "href"
> & {
  urls: MacDownloadUrls;
  fallbackUrl: string;
  autoDetect?: boolean;
  architecture?: MacArchitecture;
};

const normalizeArchitecture = (
  value?: string | null,
): MacArchitecture | null => {
  if (typeof value !== "string") {
    return null;
  }

  const normalized = value.toLowerCase();

  if (normalized === "arm" || normalized === "arm64" || normalized === "aarch64") {
    return "arm64";
  }

  if (
    normalized === "x86" ||
    normalized === "x86_64" ||
    normalized === "amd64" ||
    normalized === "x64"
  ) {
    return "x64";
  }

  return null;
};

const detectArchitectureFromWebGL = (): MacArchitecture | null => {
  if (typeof document === "undefined") {
    return null;
  }

  try {
    const canvas = document.createElement("canvas");
    const context =
      canvas.getContext("webgl2") ??
      canvas.getContext("webgl") ??
      canvas.getContext("experimental-webgl");

    if (!context) {
      return null;
    }

    const debugInfo = context.getExtension(
      "WEBGL_debug_renderer_info",
    ) as WEBGL_debug_renderer_info | null;

    if (!debugInfo) {
      return null;
    }

    const renderer = context.getParameter(debugInfo.UNMASKED_RENDERER_WEBGL);

    if (typeof renderer !== "string") {
      return null;
    }

    const normalizedRenderer = renderer.toLowerCase();

    if (
      normalizedRenderer.includes("apple m") ||
      normalizedRenderer.includes("apple gpu")
    ) {
      return "arm64";
    }

    if (
      normalizedRenderer.includes("intel") ||
      normalizedRenderer.includes("amd") ||
      normalizedRenderer.includes("nvidia")
    ) {
      return "x64";
    }

    return null;
  } catch {
    return null;
  }
};

const detectMacArchitecture = async (): Promise<MacArchitecture | null> => {
  if (typeof navigator === "undefined") {
    return null;
  }

  const platform = navigator.platform?.toLowerCase() ?? "";
  const userAgent = navigator.userAgent.toLowerCase();
  const isMac = platform.includes("mac") || userAgent.includes("macintosh");

  if (!isMac) {
    return null;
  }

  const navigatorWithUAData = navigator as Navigator & {
    userAgentData?: {
      architecture?: string;
      getHighEntropyValues?: (
        hints: readonly string[],
      ) => Promise<Record<string, unknown>>;
    };
  };

  const uaData = navigatorWithUAData.userAgentData;

  if (uaData) {
    let architectureHint = normalizeArchitecture(uaData.architecture ?? null);

    if (!architectureHint && typeof uaData.getHighEntropyValues === "function") {
      const details = await uaData
        .getHighEntropyValues(["architecture"])
        .catch(() => null);

      if (details && typeof details === "object") {
        const maybeValue = (details as Record<string, unknown>).architecture;
        architectureHint = normalizeArchitecture(
          typeof maybeValue === "string" ? maybeValue : null,
        );
      }
    }

    if (architectureHint) {
      return architectureHint;
    }
  }

  if (userAgent.includes("arm") || userAgent.includes("aarch64")) {
    return "arm64";
  }

  const webglArchitecture = detectArchitectureFromWebGL();

  if (webglArchitecture) {
    return webglArchitecture;
  }

  if (
    userAgent.includes("x86_64") ||
    userAgent.includes("x86-64") ||
    userAgent.includes("intel") ||
    userAgent.includes("amd64") ||
    userAgent.includes("x64")
  ) {
    return "x64";
  }

  return null;
};

const resolveUrl = (
  urls: MacDownloadUrls,
  architecture: MacArchitecture,
  fallbackUrl: string,
): string => {
  const candidate = urls[architecture];

  if (typeof candidate === "string" && candidate.trim() !== "") {
    return candidate;
  }

  return fallbackUrl;
};

export function MacDownloadLink({
  urls,
  fallbackUrl,
  autoDetect = false,
  architecture,
  ...anchorProps
}: MacDownloadLinkProps) {
  const sanitizedUrls = useMemo<MacDownloadUrls>(
    () => ({
      arm64:
        typeof urls.arm64 === "string" && urls.arm64.trim() !== ""
          ? urls.arm64
          : null,
      x64:
        typeof urls.x64 === "string" && urls.x64.trim() !== ""
          ? urls.x64
          : null,
    }),
    [urls.arm64, urls.x64],
  );

  const autoDefaultUrl = useMemo(() => {
    if (sanitizedUrls.arm64) {
      return sanitizedUrls.arm64;
    }

    if (sanitizedUrls.x64) {
      return sanitizedUrls.x64;
    }

    return fallbackUrl;
  }, [fallbackUrl, sanitizedUrls.arm64, sanitizedUrls.x64]);

  const explicitDefaultUrl = useMemo(() => {
    if (architecture) {
      return resolveUrl(sanitizedUrls, architecture, fallbackUrl);
    }

    return autoDefaultUrl;
  }, [architecture, autoDefaultUrl, fallbackUrl, sanitizedUrls]);

  const [href, setHref] = useState<string>(explicitDefaultUrl);

  useEffect(() => {
    setHref(explicitDefaultUrl);
  }, [explicitDefaultUrl]);

  useEffect(() => {
    if (!autoDetect) {
      return;
    }

    let isMounted = true;

    const run = async () => {
      const detectedArchitecture = await detectMacArchitecture();

      if (!isMounted || !detectedArchitecture) {
        return;
      }

      setHref(resolveUrl(sanitizedUrls, detectedArchitecture, fallbackUrl));
    };

    void run();

    return () => {
      isMounted = false;
    };
  }, [autoDetect, fallbackUrl, sanitizedUrls]);

  return <a {...anchorProps} href={href} />;
}
