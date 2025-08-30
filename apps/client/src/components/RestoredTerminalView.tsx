import { api } from "@cmux/convex/api";
import { type Id } from "@cmux/convex/dataModel";
import { createTerminalOptions } from "@cmux/shared/terminal-config";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Terminal as XTerm } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useQuery } from "convex/react";
// Read team slug from path to avoid route type coupling
import { useEffect, useRef } from "react";

export interface RestoredTerminalViewProps {
  runId: Id<"taskRuns">;
  teamSlugOrId: string;
}

export function RestoredTerminalView({
  runId,
  teamSlugOrId,
}: RestoredTerminalViewProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<XTerm | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  // Fetch log chunks from Convex
  const logChunks = useQuery(api.taskRunLogChunks.getChunks, {
    teamSlugOrId,
    taskRunId: runId,
  });

  useEffect(() => {
    if (!terminalRef.current) return;

    // Create xterm instance with same theme as TerminalView
    const xterm = new XTerm(
      createTerminalOptions({
        scrollback: 100000,
        convertEol: true,
      })
    );

    const fitAddon = new FitAddon();
    const webLinksAddon = new WebLinksAddon();

    xterm.loadAddon(fitAddon);
    xterm.loadAddon(webLinksAddon);

    xterm.open(terminalRef.current);
    fitAddon.fit();

    xtermRef.current = xterm;
    fitAddonRef.current = fitAddon;

    // Handle resize
    const handleResize = () => {
      fitAddon.fit();
    };

    const resizeObserver = new ResizeObserver(handleResize);
    resizeObserver.observe(terminalRef.current);
    window.addEventListener("resize", handleResize);

    return () => {
      resizeObserver.disconnect();
      window.removeEventListener("resize", handleResize);
      xterm.dispose();
    };
  }, []);

  // Write log chunks to terminal when they arrive
  useEffect(() => {
    if (!xtermRef.current || !logChunks) return;

    // Clear terminal before writing
    xtermRef.current.clear();

    // Concatenate all chunks to reconstruct the serialized data
    const serializedData = logChunks
      .map((chunk: { content: string }) => chunk.content)
      .join("");

    // Write the serialized data to restore the terminal state
    if (serializedData) {
      xtermRef.current.write(serializedData);
    }
  }, [logChunks]);

  return (
    <div className="flex flex-col grow relative">
      <div
        ref={terminalRef}
        className="w-full h-full"
        style={{
          backgroundColor: "#1e1e1e",
        }}
      />
    </div>
  );
}
