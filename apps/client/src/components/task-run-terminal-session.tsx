import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AttachAddon } from "@xterm/addon-attach";
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { WebglAddon } from "@xterm/addon-webgl";
import {
  ACTIVE_TERMINAL_SCROLLBACK,
  INACTIVE_TERMINAL_SCROLLBACK,
} from "@cmux/shared/terminal-config";
import clsx from "clsx";
import { useXTerm } from "./xterm/use-xterm";

const MIN_COLS = 20;
const MAX_COLS = 320;
const MIN_ROWS = 8;
const MAX_ROWS = 120;

export type TerminalConnectionState =
  | "connecting"
  | "open"
  | "closed"
  | "error";

interface TaskRunTerminalSessionProps {
  baseUrl: string;
  terminalId: string;
  isActive: boolean;
  onConnectionStateChange?: (state: TerminalConnectionState) => void;
  onReconnectAll?: () => void;
  isReconnecting?: boolean;
}

function clampDimension(value: number, min: number, max: number, fallback: number) {
  const next = Number.isFinite(value) && value > 0 ? Math.round(value) : fallback;
  return Math.max(min, Math.min(max, next));
}

export function TaskRunTerminalSession({
  baseUrl,
  terminalId,
  isActive,
  onConnectionStateChange,
  onReconnectAll,
  isReconnecting,
}: TaskRunTerminalSessionProps) {
  const callbackRef = useRef<TaskRunTerminalSessionProps["onConnectionStateChange"]>(
    onConnectionStateChange
  );
  useEffect(() => {
    callbackRef.current = onConnectionStateChange;
  }, [onConnectionStateChange]);

  const [connectionState, setConnectionState] = useState<TerminalConnectionState>(
    "connecting"
  );

  const {
    ref: containerRef,
    instance: terminal,
  } = useXTerm();

  const fitAddonRef = useRef<FitAddon | null>(null);

  useEffect(() => {
    if (!terminal) {
      return;
    }

    const nextScrollback = isActive
      ? ACTIVE_TERMINAL_SCROLLBACK
      : INACTIVE_TERMINAL_SCROLLBACK;

    if (terminal.options.scrollback !== nextScrollback) {
      terminal.options.scrollback = nextScrollback;
    }

    if (!isActive) {
      terminal.clear();
    }
  }, [isActive, terminal]);

  useEffect(() => {
    if (!terminal) {
      fitAddonRef.current = null;
      return;
    }

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();
    const searchAddon = new SearchAddon();
    const unicodeAddon = new Unicode11Addon();

    terminal.loadAddon(fitAddon);
    terminal.loadAddon(webLinksAddon);
    terminal.loadAddon(searchAddon);
    terminal.loadAddon(unicodeAddon);

    fitAddonRef.current = fitAddon;

    return () => {
      fitAddon.dispose();
      webLinksAddon.dispose();
      searchAddon.dispose();
      unicodeAddon.dispose();
      fitAddonRef.current = null;
    };
  }, [terminal]);

  useEffect(() => {
    if (!terminal || !isActive) {
      return;
    }

    let webglAddon: WebglAddon | null = null;
    try {
      webglAddon = new WebglAddon();
      terminal.loadAddon(webglAddon);
    } catch (error) {
      console.warn("[TaskRunTerminalSession] WebGL addon unavailable", error);
      if (webglAddon) {
        webglAddon.dispose();
        webglAddon = null;
      }
    }

    return () => {
      if (webglAddon) {
        webglAddon.dispose();
      }
    };
  }, [isActive, terminal]);

  const socketRef = useRef<WebSocket | null>(null);
  const attachAddonRef = useRef<AttachAddon | null>(null);
  const pendingResizeRef = useRef<{ cols: number; rows: number } | null>(null);
  const lastSentResizeRef = useRef<{ cols: number; rows: number } | null>(null);

  const notifyConnectionState = useCallback((next: TerminalConnectionState) => {
    setConnectionState(next);
    callbackRef.current?.(next);
  }, []);

  const queueResize = useCallback(() => {
    if (!terminal) {
      pendingResizeRef.current = null;
      return;
    }

    const cols = clampDimension(terminal.cols, MIN_COLS, MAX_COLS, 80);
    const rows = clampDimension(terminal.rows, MIN_ROWS, MAX_ROWS, 24);
    const current = { cols, rows };

    const last = lastSentResizeRef.current;
    if (last && last.cols === current.cols && last.rows === current.rows) {
      pendingResizeRef.current = null;
      return;
    }

    const socket = socketRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: "resize", cols: current.cols, rows: current.rows }));
      lastSentResizeRef.current = current;
      pendingResizeRef.current = null;
    } else {
      pendingResizeRef.current = current;
    }
  }, [terminal]);

  const measureAndQueueResize = useCallback(() => {
    const fitAddon = fitAddonRef.current;
    if (!terminal || !fitAddon) {
      return;
    }
    fitAddon.fit();
    queueResize();
  }, [queueResize, terminal]);

  const flushPendingResize = useCallback(() => {
    if (!pendingResizeRef.current) {
      return;
    }
    const socket = socketRef.current;
    if (socket && socket.readyState === WebSocket.OPEN) {
      const next = pendingResizeRef.current;
      pendingResizeRef.current = null;
      if (next) {
        socket.send(JSON.stringify({ type: "resize", cols: next.cols, rows: next.rows }));
        lastSentResizeRef.current = next;
      }
    }
  }, []);

  useEffect(() => {
    if (!terminal || !isActive) {
      return;
    }

    const disposable = terminal.onResize(() => {
      queueResize();
    });

    return () => {
      disposable.dispose();
    };
  }, [isActive, queueResize, terminal]);

  // Observe container resizes and propagate them to the backend
  useEffect(() => {
    if (!isActive) {
      return undefined;
    }

    const container = containerRef.current;
    if (!container) {
      return undefined;
    }

    let frame = 0;
    const handle = () => {
      frame = window.requestAnimationFrame(() => {
        measureAndQueueResize();
      });
    };

    const observer = new ResizeObserver(handle);
    observer.observe(container);
    window.addEventListener("resize", handle);

    // Initial fit and resize message
    measureAndQueueResize();

    return () => {
      observer.disconnect();
      window.removeEventListener("resize", handle);
      window.cancelAnimationFrame(frame);
    };
  }, [containerRef, isActive, measureAndQueueResize]);

  // Manage WebSocket lifecycle
  useEffect(() => {
    if (!terminal) {
      notifyConnectionState("connecting");
      return undefined;
    }

    if (!isActive) {
      notifyConnectionState("closed");
      return undefined;
    }

    let cancelled = false;
    const base = new URL(baseUrl);
    const wsUrl = new URL(`/sessions/${terminalId}/ws`, base);
    wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";

    terminal.clear();
    pendingResizeRef.current = null;
    lastSentResizeRef.current = null;

    const socket = new WebSocket(wsUrl);
    socket.binaryType = "arraybuffer";
    socketRef.current = socket;

    const attachAddon = new AttachAddon(socket, { bidirectional: true });
    attachAddonRef.current = attachAddon;
    terminal.loadAddon(attachAddon);

    notifyConnectionState("connecting");

    const handleOpen = () => {
      if (cancelled) {
        return;
      }
      notifyConnectionState("open");
      // Ensure terminal dimensions are synchronised once the socket is ready
      measureAndQueueResize();
      flushPendingResize();
    };

    const handleClose = () => {
      if (cancelled) {
        return;
      }
      notifyConnectionState("closed");
    };

    const handleError = () => {
      if (cancelled) {
        return;
      }
      notifyConnectionState("error");
    };

    socket.addEventListener("open", handleOpen);
    socket.addEventListener("close", handleClose);
    socket.addEventListener("error", handleError);

    return () => {
      cancelled = true;
      socket.removeEventListener("open", handleOpen);
      socket.removeEventListener("close", handleClose);
      socket.removeEventListener("error", handleError);

      attachAddon.dispose();
      attachAddonRef.current = null;

      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close();
      }

      if (socketRef.current === socket) {
        socketRef.current = null;
      }
    };
  }, [
    baseUrl,
    flushPendingResize,
    isActive,
    measureAndQueueResize,
    notifyConnectionState,
    terminal,
    terminalId,
  ]);

  useEffect(() => {
    if (!terminal) {
      return;
    }

    if (isActive) {
      measureAndQueueResize();
      // Defer focus to avoid triggering terminal queries during panel transitions
      // Use double RAF to ensure resize operations are fully complete
      // This prevents special characters from appearing when panels are swapped
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          if (terminal && isActive) {
            terminal.focus();
          }
        });
      });
    }
  }, [isActive, measureAndQueueResize, terminal]);

  const statusMessage = useMemo(() => {
    switch (connectionState) {
      case "open":
        return null;
      case "error":
        return "Failed to connect to the terminal backend.";
      case "closed":
        return "Terminal connection closed.";
      case "connecting":
      default:
        return "Connecting to terminal…";
    }
  }, [connectionState]);

  const showReconnectButton =
    (connectionState === "closed" || connectionState === "error") &&
    Boolean(onReconnectAll);

  return (
    <div
      className={clsx("relative w-full h-full", { hidden: !isActive })}
      role="tabpanel"
      aria-hidden={!isActive}
      data-terminal-id={terminalId}
    >
      <div ref={containerRef} className="absolute inset-0" />
      {statusMessage ? (
        <div className="absolute inset-0 flex items-center justify-center bg-neutral-950/60">
          <div className="flex flex-col items-center gap-3 text-center">
            <span className="text-sm text-neutral-200 dark:text-neutral-300">
              {statusMessage}
            </span>
            {showReconnectButton ? (
              <button
                type="button"
                onClick={onReconnectAll}
                disabled={isReconnecting}
                className="rounded-md bg-neutral-100 px-3 py-1.5 text-xs font-medium text-neutral-900 transition hover:bg-neutral-200 disabled:cursor-not-allowed disabled:opacity-60 dark:bg-neutral-800 dark:text-neutral-100 dark:hover:bg-neutral-700"
              >
                {isReconnecting ? "Reconnecting…" : "Reconnect terminals"}
              </button>
            ) : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}
