import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { FitAddon } from "@xterm/addon-fit";
import { AttachAddon } from "@xterm/addon-attach";
import { WebglAddon } from "@xterm/addon-webgl";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { useXTerm } from "@/components/xterm/use-xterm";
import { Button } from "@/components/ui/button";
import clsx from "clsx";
import { Terminal as TerminalIcon, RefreshCw, WifiOff } from "lucide-react";

const TERMINAL_THEME = {
  background: "#0f172a",
  foreground: "#e2e8f0",
  cursor: "#38bdf8",
  selectionBackground: "rgba(56,189,248,0.35)",
  selectionForeground: "#0f172a",
};

const DEFAULT_COLS = 100;
const DEFAULT_ROWS = 28;
const MIN_COLS = 20;
const MAX_COLS = 320;
const MIN_ROWS = 8;
const MAX_ROWS = 120;
const TMUX_SESSION_TARGET = "cmux:dev";
const TMUX_ATTACH_ARGS = ["attach-session", "-t", TMUX_SESSION_TARGET];
const CREATE_TIMEOUT_MS = 20_000;

export type DevPreviewTerminalStatus =
  | "idle"
  | "starting"
  | "connected"
  | "disconnected"
  | "error";

export interface DevPreviewTerminalProps {
  endpoint?: string | null;
  visible: boolean;
  className?: string;
  onStatusChange?: (status: DevPreviewTerminalStatus) => void;
}

function clamp(value: number, min: number, max: number) {
  if (!Number.isFinite(value)) {
    return min;
  }
  return Math.min(max, Math.max(min, Math.round(value)));
}

function buildUrl(base: string, path: string) {
  return new URL(path, base).toString();
}

export function DevPreviewTerminal({
  endpoint,
  visible,
  className,
  onStatusChange,
}: DevPreviewTerminalProps) {
  const fitAddon = useMemo(() => new FitAddon(), []);
  const webLinksAddon = useMemo(() => new WebLinksAddon(), []);
  const searchAddon = useMemo(() => new SearchAddon(), []);
  const unicodeAddon = useMemo(() => new Unicode11Addon(), []);

  const { ref: terminalRef, instance: terminal } = useXTerm({
    options: {
      allowProposedApi: true,
      cursorBlink: true,
      scrollback: 200_000,
      fontFamily: '"JetBrains Mono", "Fira Code", monospace',
      fontSize: 13,
      theme: TERMINAL_THEME,
    },
    addons: [fitAddon, webLinksAddon, searchAddon, unicodeAddon],
  });

  const [status, setStatusState] = useState<DevPreviewTerminalStatus>("idle");
  const statusRef = useRef<DevPreviewTerminalStatus>("idle");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [connectAttempt, setConnectAttempt] = useState(0);

  const socketRef = useRef<WebSocket | null>(null);
  const attachAddonRef = useRef<AttachAddon | null>(null);
  const sessionRef = useRef<{ id: string; endpoint: string } | null>(null);
  const resizeObserverRef = useRef<ResizeObserver | null>(null);
  const webglAddonRef = useRef<WebglAddon | null>(null);

  const updateStatus = useCallback(
    (next: DevPreviewTerminalStatus) => {
      statusRef.current = next;
      setStatusState(next);
    },
    [],
  );

  useEffect(() => {
    if (!onStatusChange) return;
    onStatusChange(status);
  }, [onStatusChange, status]);

  useEffect(() => {
    if (!terminal) return;
    let webgl: WebglAddon | null = null;
    try {
      webgl = new WebglAddon();
      terminal.loadAddon(webgl);
      webgl.onContextLoss(() => {
        webgl?.dispose();
        webglAddonRef.current = null;
      });
      webglAddonRef.current = webgl;
    } catch {
      webgl?.dispose();
      webglAddonRef.current = null;
    }
    return () => {
      webglAddonRef.current?.dispose();
      webglAddonRef.current = null;
    };
  }, [terminal]);

  const disposeAttach = useCallback(() => {
    attachAddonRef.current?.dispose();
    attachAddonRef.current = null;
  }, []);

  const closeSocket = useCallback(() => {
    const socket = socketRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.close();
    }
    socketRef.current = null;
  }, []);

  const cleanupSession = useCallback(
    (options?: { delete?: boolean }) => {
      disposeAttach();
      closeSocket();
      const session = sessionRef.current;
      sessionRef.current = null;
      if (options?.delete && session) {
        const deleteUrl = buildUrl(session.endpoint, `/api/tabs/${session.id}`);
        void fetch(deleteUrl, { method: "DELETE" }).catch(() => {
          // Ignore cleanup failures.
        });
      }
    },
    [closeSocket, disposeAttach],
  );

  const normalizedDimensions = useCallback(() => {
    if (!terminal) {
      return { cols: DEFAULT_COLS, rows: DEFAULT_ROWS };
    }
    const cols = clamp(terminal.cols || DEFAULT_COLS, MIN_COLS, MAX_COLS);
    const rows = clamp(terminal.rows || DEFAULT_ROWS, MIN_ROWS, MAX_ROWS);
    return { cols, rows };
  }, [terminal]);

  const fitAndResize = useCallback(() => {
    if (!terminal) {
      return { cols: DEFAULT_COLS, rows: DEFAULT_ROWS };
    }
    fitAddon.fit();
    const dims = normalizedDimensions();
    const socket = socketRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      try {
        socket.send(
          JSON.stringify({ type: "resize", cols: dims.cols, rows: dims.rows }),
        );
      } catch {
        // Ignore resize errors.
      }
    }
    return dims;
  }, [fitAddon, normalizedDimensions, terminal]);

  useEffect(() => {
    if (!terminal || !visible) {
      return;
    }
    const handle = window.requestAnimationFrame(() => {
      fitAndResize();
      terminal.focus();
    });
    return () => {
      window.cancelAnimationFrame(handle);
    };
  }, [fitAndResize, terminal, visible]);

  useEffect(() => {
    if (!visible) {
      updateStatus("idle");
      setErrorMessage(null);
      cleanupSession({ delete: true });
      return;
    }
    if (!endpoint || !terminal) {
      return;
    }

    let disposed = false;
    const controller = new AbortController();

    const connect = async () => {
      cleanupSession({ delete: true });
      updateStatus("starting");
      setErrorMessage(null);

      const dims = fitAndResize();
      const body = JSON.stringify({
        cmd: "tmux",
        args: TMUX_ATTACH_ARGS,
        cols: dims.cols,
        rows: dims.rows,
      });

      const createUrl = buildUrl(endpoint, "/api/tabs");
      let timeoutId: ReturnType<typeof setTimeout> | null = null;
      try {
        const createPromise = fetch(createUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body,
          signal: controller.signal,
        });
        const timeoutPromise = new Promise<Response>((_, reject) => {
          timeoutId = setTimeout(() => {
            reject(new Error("Timed out creating terminal"));
          }, CREATE_TIMEOUT_MS);
        });
        const response = await Promise.race([createPromise, timeoutPromise]);
        if (!response.ok) {
          throw new Error(`Failed to create terminal (${response.status})`);
        }
        const payload = (await response.json()) as { id: string; ws_url?: string };
        if (disposed) {
          cleanupSession({ delete: true });
          return;
        }

        sessionRef.current = { id: payload.id, endpoint };

        const rawWsUrl = payload.ws_url ?? `/ws/${payload.id}`;
        const wsUrl = new URL(rawWsUrl, endpoint);
        wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
        const socket = new WebSocket(wsUrl.toString());
        socket.binaryType = "arraybuffer";
        socketRef.current = socket;

        const attachAddon = new AttachAddon(socket, { bidirectional: true });
        attachAddonRef.current = attachAddon;
        terminal.loadAddon(attachAddon);

        socket.addEventListener("open", () => {
          if (disposed) {
            return;
          }
          updateStatus("connected");
          setErrorMessage(null);
          window.requestAnimationFrame(() => {
            fitAndResize();
            terminal.focus();
          });
        });

        socket.addEventListener("message", (event) => {
          if (typeof event.data === "string") {
            return;
          }
          // Binary frames handled by AttachAddon; no-op.
        });

        socket.addEventListener("close", (closeEvent) => {
          if (disposed) {
            return;
          }
          disposeAttach();
          socketRef.current = null;
          const wasStarting = statusRef.current === "starting";
          if (wasStarting && !closeEvent.wasClean) {
            setErrorMessage(
              "Dev script tmux session is not ready yet. Re-open once it starts.",
            );
            updateStatus("error");
          } else if (closeEvent.wasClean) {
            updateStatus("disconnected");
          } else {
            setErrorMessage("Terminal connection closed unexpectedly.");
            updateStatus("error");
          }
        });

        socket.addEventListener("error", () => {
          if (disposed) {
            return;
          }
          setErrorMessage("Unable to reach the dev terminal service.");
          updateStatus("error");
        });
      } catch (error) {
        if (disposed || controller.signal.aborted) {
          return;
        }
        const message =
          error instanceof Error ? error.message : "Failed to start terminal";
        setErrorMessage(message);
        updateStatus("error");
        cleanupSession({ delete: true });
      } finally {
        if (timeoutId) {
          clearTimeout(timeoutId);
        }
      }
    };

    void connect();

    const element = terminalRef.current;
    const observer = new ResizeObserver(() => {
      fitAndResize();
    });
    if (element) {
      observer.observe(element);
      resizeObserverRef.current = observer;
    }

    const handleWindowResize = () => {
      window.requestAnimationFrame(() => {
        fitAndResize();
      });
    };

    window.addEventListener("resize", handleWindowResize);

    return () => {
      disposed = true;
      controller.abort();
      window.removeEventListener("resize", handleWindowResize);
      observer.disconnect();
      resizeObserverRef.current = null;
      cleanupSession({ delete: true });
    };
  }, [cleanupSession, connectAttempt, disposeAttach, endpoint, fitAndResize, terminal, terminalRef, updateStatus, visible]);

  const reconnect = useCallback(() => {
    setConnectAttempt((value) => value + 1);
  }, []);

  const statusLabel = useMemo(() => {
    switch (status) {
      case "idle":
        return "Hidden";
      case "starting":
        return "Connecting";
      case "connected":
        return "Live";
      case "disconnected":
        return "Disconnected";
      case "error":
        return "Error";
      default:
        return status;
    }
  }, [status]);

  const statusTone = useMemo(() => {
    switch (status) {
      case "connected":
        return "text-emerald-400";
      case "starting":
        return "text-sky-300";
      case "error":
        return "text-rose-400";
      default:
        return "text-neutral-300";
    }
  }, [status]);

  const canReconnect = status === "error" || status === "disconnected";
  const isUnavailable = !endpoint;

  return (
    <div
      className={clsx(
        "flex h-full min-h-0 flex-col overflow-hidden rounded-lg border border-neutral-200/30 bg-neutral-900/90 shadow-[0_30px_80px_-40px_rgba(15,23,42,0.8)] backdrop-blur dark:border-neutral-800/60",
        className,
      )}
    >
      <div className="flex items-center justify-between border-b border-neutral-800/60 px-3 py-2">
        <div className="flex flex-col gap-0.5">
          <span className="text-[11px] font-semibold uppercase tracking-[0.18em] text-neutral-400">
            Dev Script Terminal
          </span>
          <div className="flex items-center gap-2 text-sm text-neutral-200">
            <span className={clsx("flex items-center gap-1 font-medium", statusTone)}>
              <span className="inline-flex size-1.5 rounded-full bg-current" />
              {statusLabel}
            </span>
            <span className="text-[11px] text-neutral-500 dark:text-neutral-400">
              tmux {TMUX_SESSION_TARGET}
            </span>
          </div>
        </div>
        <div className="flex items-center gap-2">
          {isUnavailable ? (
            <span className="inline-flex items-center gap-1 rounded-full bg-neutral-800/70 px-2 py-1 text-[11px] font-medium text-neutral-400">
              <WifiOff className="size-3" />
              Not published
            </span>
          ) : null}
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={!canReconnect || isUnavailable}
            onClick={reconnect}
            className={clsx(
              "cursor-pointer border-neutral-700 bg-neutral-900 text-neutral-200 hover:bg-neutral-800",
              (!canReconnect || isUnavailable) && "cursor-not-allowed opacity-50",
            )}
          >
            <RefreshCw className="size-3.5" />
            Reconnect
          </Button>
        </div>
      </div>
      <div className="relative flex-1 bg-[#0b1224]">
        <div ref={terminalRef} className="absolute inset-0" />
        {!visible || isUnavailable ? (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 bg-[#0b1224] text-center text-neutral-400">
            <TerminalIcon className="size-5 text-neutral-500" />
            <p className="text-sm font-medium">
              {isUnavailable
                ? "Terminal service is not available for this run."
                : "Enable the terminal to view dev script output."}
            </p>
          </div>
        ) : null}
        {visible && status !== "connected" && !isUnavailable ? (
          <div className="pointer-events-none absolute inset-0 flex items-end justify-start bg-gradient-to-t from-[#0b1224] via-[#0b1224]/85 to-transparent p-3">
            <div className="rounded-md border border-neutral-800/70 bg-neutral-900/70 px-3 py-2 text-left text-xs text-neutral-300">
              <p className="font-medium">{statusLabel}</p>
              {errorMessage ? (
                <p className="mt-1 text-[11px] text-neutral-400">{errorMessage}</p>
              ) : (
                <p className="mt-1 text-[11px] text-neutral-400">
                  Waiting for the dev script tmux window to become available…
                </p>
              )}
            </div>
          </div>
        ) : null}
      </div>
      <div className="flex items-center justify-between border-t border-neutral-800/60 bg-neutral-950/60 px-3 py-2 text-[11px] text-neutral-400">
        <span>Shift+Insert to paste</span>
        <span>Ctrl+Shift+F to search</span>
      </div>
    </div>
  );
}
