import { useEffect, useMemo, useRef, useState } from "react";
import {
  extractMorphInstanceInfo,
  isIframePreflightPhasePayload,
  isIframePreflightResult,
  isLoopbackHostname,
  type IframePreflightPhasePayload,
  type IframePreflightResult,
  type IframePreflightServerPhase,
} from "@cmux/shared";
import { WWW_ORIGIN } from "@/lib/wwwOrigin";
import { useSocket } from "@/contexts/socket/use-socket";
import { useUser } from "@stackframe/react";

export type IframePreflightPhase =
  | "idle"
  | "loading"
  | "resuming"
  | "ready"
  | "resume_failed"
  | "instance_not_found"
  | "preflight_failed"
  | "error";

export type { IframePreflightResult } from "@cmux/shared";

export interface UseIframePreflightOptions {
  url: string | null | undefined;
  enabled?: boolean;
}

export interface UseIframePreflightState {
  phase: IframePreflightPhase;
  phasePayload: IframePreflightPhasePayload | null;
  result: IframePreflightResult | null;
  error: string | null;
  isMorphTarget: boolean;
}

type ParsedEvent = {
  event: string;
  data: string;
};

export function shouldUseIframePreflightProxy(
  target: string | URL | null | undefined
): boolean {
  if (!target) {
    return false;
  }

  try {
    return extractMorphInstanceInfo(target) !== null;
  } catch {
    return false;
  }
}

export function shouldUseServerIframePreflight(
  target: string | URL | null | undefined
): boolean {
  if (!target) {
    return false;
  }

  try {
    const url = typeof target === "string" ? new URL(target) : target;
    return isLoopbackHostname(url.hostname);
  } catch {
    return false;
  }
}

const EVENT_SEPARATOR = "\n\n";

function parseEventBlock(block: string): ParsedEvent | null {
  if (!block.trim()) {
    return null;
  }

  const lines = block.split("\n");
  let event = "message";
  const dataLines: string[] = [];

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith(":")) {
      continue;
    }

    if (line.startsWith("event:")) {
      event = line.slice("event:".length).trim();
      continue;
    }

    if (line.startsWith("data:")) {
      dataLines.push(line.slice("data:".length).trimStart());
    }
  }

  return {
    event,
    data: dataLines.join("\n"),
  };
}

function applyPhaseMapping(
  phase: IframePreflightServerPhase
): IframePreflightPhase | null {
  switch (phase) {
    case "resuming":
    case "resume_retry":
    case "resumed":
      return "resuming";
    case "already_ready":
    case "ready":
      return "ready";
    case "resume_failed":
      return "resume_failed";
    case "resume_forbidden":
      return "resume_failed";
    case "instance_not_found":
      return "instance_not_found";
    case "preflight_failed":
      return "preflight_failed";
    case "error":
      return "error";
    default:
      return null;
  }
}

export function useIframePreflight({
  url,
  enabled = true,
}: UseIframePreflightOptions): UseIframePreflightState {
  const user = useUser({ or: "redirect" });
  const [phase, setPhase] = useState<IframePreflightPhase>("idle");
  const [phasePayload, setPhasePayload] =
    useState<IframePreflightPhasePayload | null>(null);
  const [result, setResult] = useState<IframePreflightResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const phaseRef = useRef<IframePreflightPhase>("idle");
  const { socket } = useSocket();

  // Track the URL to prevent unnecessary preflight restarts when URL reference changes but value is the same
  const prevUrlRef = useRef<string | null | undefined>(url);
  const stableUrl = useMemo(() => {
    if (url === prevUrlRef.current) {
      return prevUrlRef.current;
    }
    prevUrlRef.current = url;
    return url;
  }, [url]);

  type PreflightMode = "morph" | "server";

  const preflightMode = useMemo<PreflightMode | null>(() => {
    if (!stableUrl) {
      return null;
    }
    if (shouldUseIframePreflightProxy(stableUrl)) {
      return "morph";
    }
    if (shouldUseServerIframePreflight(stableUrl)) {
      return "server";
    }
    return null;
  }, [stableUrl]);

  const isMorphTarget = preflightMode === "morph";

  const updatePhase = (next: IframePreflightPhase) => {
    if (phaseRef.current === next) {
      return;
    }
    phaseRef.current = next;
    setPhase(next);
  };

  useEffect(() => {
    if (
      !enabled ||
      !stableUrl ||
      !preflightMode ||
      (preflightMode === "server" && !socket)
    ) {
      abortRef.current?.abort();
      abortRef.current = null;
      phaseRef.current = "idle";
      setPhase("idle");
      setPhasePayload(null);
      setResult(null);
      setError(null);
      return;
    }

    if (typeof window === "undefined" || typeof fetch === "undefined") {
      return;
    }

    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    phaseRef.current = "loading";
    setPhase("loading");
    setPhasePayload(null);
    setResult(null);
    setError(null);

    let cancelled = false;

    const handlePhaseEvent = (payload: IframePreflightPhasePayload) => {
      if (cancelled) {
        return;
      }
      setPhasePayload(payload);
      const mapped = applyPhaseMapping(payload.phase);
      if (mapped) {
        updatePhase(mapped);
      }
    };

    const handleResultEvent = (payload: IframePreflightResult) => {
      if (cancelled) {
        return;
      }
      setResult(payload);
      if (payload.ok) {
        updatePhase("ready");
        setError(null);
        return;
      }

      const message = payload.error ?? "Iframe preflight failed.";
      setError(message);
      if (
        phaseRef.current !== "resume_failed" &&
        phaseRef.current !== "instance_not_found" &&
        phaseRef.current !== "error"
      ) {
        updatePhase("preflight_failed");
      }
    };

    const runMorphPreflight = async () => {
      try {
        const requestUrl = new URL("/api/iframe/preflight", WWW_ORIGIN);
        requestUrl.search = new URLSearchParams({ url: stableUrl }).toString();
        const stackHeaders = await user.getAuthHeaders();

        const response = await fetch(requestUrl, {
          method: "GET",
          cache: "no-store",
          credentials: "include",
          signal: controller.signal,
          headers: {
            Accept: "text/event-stream",
            ...stackHeaders,
          },
        });

        if (!response.ok) {
          if (cancelled || controller.signal.aborted) {
            return;
          }

          let message = `Preflight request failed (status ${response.status})`;
          try {
            const data = await response.json();
            if (
              isIframePreflightResult(data) &&
              typeof data.error === "string" &&
              data.error
            ) {
              message = data.error;
            }
          } catch {
            // Ignore JSON parse errors; keep fallback message.
          }

          setResult({
            ok: false,
            status: response.status,
            method: null,
            error: message,
          });
          setError(message);
          updatePhase("error");
          return;
        }

        if (!response.body) {
          if (cancelled || controller.signal.aborted) {
            return;
          }
          setError("Preflight response did not include a body stream.");
          setResult({
            ok: false,
            status: null,
            method: null,
            error: "Preflight response did not include a body stream.",
          });
          updatePhase("error");
          return;
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        const closeReader = async () => {
          try {
            await reader.cancel();
          } catch {
            // ignore
          }
        };

        const processEvent = (event: ParsedEvent) => {
          if (event.event === "phase") {
            try {
              const parsed = JSON.parse(event.data);
              if (isIframePreflightPhasePayload(parsed)) {
                handlePhaseEvent(parsed);
              }
            } catch {
              // ignore malformed JSON
            }
            return;
          }

          if (event.event === "result") {
            try {
              const parsed = JSON.parse(event.data);
              if (isIframePreflightResult(parsed)) {
                handleResultEvent(parsed);
              }
            } catch {
              // ignore malformed JSON
            }
          }
        };

        while (true) {
          const { done, value } = await reader.read();
          if (controller.signal.aborted) {
            await closeReader();
            return;
          }

          if (done) {
            buffer += decoder.decode();
            buffer = buffer.replace(/\r\n/g, "\n");
            if (buffer.trim()) {
              const event = parseEventBlock(buffer);
              if (event) {
                processEvent(event);
              }
            }
            break;
          }

          const chunk = decoder
            .decode(value, { stream: true })
            .replace(/\r\n/g, "\n");
          buffer += chunk;

          while (true) {
            const separatorIndex = buffer.indexOf(EVENT_SEPARATOR);
            if (separatorIndex === -1) {
              break;
            }

            const block = buffer.slice(0, separatorIndex);
            buffer = buffer.slice(separatorIndex + EVENT_SEPARATOR.length);
            const event = parseEventBlock(block);
            if (!event) {
              continue;
            }
            processEvent(event);
          }
        }
      } catch (err) {
        if (cancelled || controller.signal.aborted) {
          return;
        }

        const message =
          err instanceof Error ? err.message : "Preflight request failed.";
        setError(message);
        setResult({
          ok: false,
          status: null,
          method: null,
          error: message,
        });
        updatePhase("error");
      }
    };

    const runServerPreflight = async () => {
      try {
        const payload = await new Promise<IframePreflightResult>(
          (resolve, reject) => {
            if (!socket) {
              reject(new Error("Socket is not connected."));
              return;
            }
            socket.emit("iframe-preflight", { url: stableUrl }, (response) => {
              if (cancelled || controller.signal.aborted) {
                return;
              }
              if (isIframePreflightResult(response)) {
                resolve(response);
                return;
              }
              reject(new Error("Preflight response was malformed."));
            });
          }
        );

        if (cancelled || controller.signal.aborted) {
          return;
        }

        handleResultEvent(payload);
      } catch (err) {
        if (cancelled || controller.signal.aborted) {
          return;
        }

        const message =
          err instanceof Error ? err.message : "Preflight request failed.";
        setError(message);
        setResult({
          ok: false,
          status: null,
          method: null,
          error: message,
        });
        updatePhase("error");
      }
    };

    if (preflightMode === "morph") {
      void runMorphPreflight();
    } else {
      void runServerPreflight();
    }

    return () => {
      cancelled = true;
      controller.abort();
      abortRef.current = null;
    };
  }, [enabled, preflightMode, socket, stableUrl, user]);

  return {
    phase,
    phasePayload,
    result,
    error,
    isMorphTarget,
  };
}
