import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { useEffect, useMemo, useRef } from "react";
import { useXTerm } from "./xterm/use-xterm";

interface TerminalProps {
  terminalId: string;
  isActive: boolean;
  initialScrollback?: string[];
}

export function Terminal({ isActive, initialScrollback }: TerminalProps) {
  const fitAddon = useMemo(() => new FitAddon(), []);
  const webLinksAddon = useMemo(() => new WebLinksAddon(), []);
  const addons = useMemo(
    () => [fitAddon, webLinksAddon],
    [fitAddon, webLinksAddon]
  );

  const { ref: terminalRef, instance: terminal } = useXTerm({
    addons,
  });

  useEffect(() => {
    if (!terminal) return;

    const handleResize = () => {
      if (fitAddon && terminal.element?.isConnected) {
        try {
          fitAddon.fit();
        } catch (error) {
          console.debug("[Terminal] fitAddon.fit() failed during resize", error);
        }
      }
    };

    // Guard against calling fit() when terminal is not fully initialized
    if (terminal.element?.isConnected) {
      try {
        fitAddon.fit();
      } catch (error) {
        console.debug("[Terminal] fitAddon.fit() failed during mount", error);
      }
    }

    window.addEventListener("resize", handleResize);

    return () => {
      window.removeEventListener("resize", handleResize);
      terminal.dispose();
    };
  }, [terminal, fitAddon]);

  const hasWrittenInitialScrollback = useRef(false);
  useEffect(() => {
    if (!terminal) return;
    if (
      initialScrollback &&
      initialScrollback.length > 0 &&
      !hasWrittenInitialScrollback.current
    ) {
      terminal.write(initialScrollback.join(""));
      hasWrittenInitialScrollback.current = true;
    }
  }, [initialScrollback, terminal, hasWrittenInitialScrollback]);

  useEffect(() => {
    if (isActive && terminal && terminal.element?.isConnected) {
      try {
        fitAddon.fit();
      } catch (error) {
        console.debug("[Terminal] fitAddon.fit() failed when becoming active", error);
      }
      terminal.focus();
    }
  }, [isActive, fitAddon, terminal]);

  return (
    <div
      ref={terminalRef}
      style={{
        width: "100%",
        height: "100%",
        backgroundColor: "#1e1e1e",
      }}
    />
  );
}
