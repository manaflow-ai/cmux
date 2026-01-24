"use client";

import { useEffect, useRef } from "react";
import clsx from "clsx";
import type { TerminalLine } from "./types";

interface TerminalOutputProps {
  lines: TerminalLine[];
  className?: string;
}

export function TerminalOutput({ lines, className }: TerminalOutputProps) {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }
  }, [lines]);

  return (
    <div
      ref={containerRef}
      className={clsx(
        "bg-neutral-950 rounded-lg font-mono text-sm overflow-auto",
        className
      )}
    >
      <div className="p-4 space-y-1">
        {lines.length === 0 ? (
          <div className="text-neutral-500 text-xs">
            Terminal output will appear here...
          </div>
        ) : (
          lines.map((line) => (
            <div key={line.id} className="flex">
              {line.type === "command" && (
                <>
                  <span className="text-emerald-400 mr-2 select-none">$</span>
                  <span className="text-neutral-100">{line.content}</span>
                </>
              )}
              {line.type === "output" && (
                <span className="text-neutral-400 pl-4">{line.content}</span>
              )}
              {line.type === "success" && (
                <span className="text-emerald-400 pl-4">{line.content}</span>
              )}
              {line.type === "error" && (
                <span className="text-red-400 pl-4">{line.content}</span>
              )}
              {line.type === "info" && (
                <span className="text-blue-400 pl-4">{line.content}</span>
              )}
            </div>
          ))
        )}
        <div className="flex items-center">
          <span className="text-emerald-400 mr-2 select-none">$</span>
          <span className="w-2 h-4 bg-neutral-400 animate-pulse" />
        </div>
      </div>
    </div>
  );
}
