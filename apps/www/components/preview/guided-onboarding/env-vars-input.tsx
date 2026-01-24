"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Plus, Minus, Eye, EyeOff, Upload } from "lucide-react";
import clsx from "clsx";

const MASKED_VALUE = "••••••••••••••••";

type EnvVar = { name: string; value: string };

interface EnvVarsInputProps {
  initialVars?: EnvVar[];
  onSubmit: (vars: EnvVar[]) => void;
  onSkip: () => void;
  disabled?: boolean;
}

function parseEnvBlock(text: string): EnvVar[] {
  const normalized = text.replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");
  const results: EnvVar[] = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (
      trimmed.length === 0 ||
      trimmed.startsWith("#") ||
      trimmed.startsWith("//")
    )
      continue;

    const cleanLine = trimmed.replace(/^export\s+/, "").replace(/^set\s+/, "");
    const eqIdx = cleanLine.indexOf("=");

    if (eqIdx === -1) continue;

    const key = cleanLine.slice(0, eqIdx).trim();
    let value = cleanLine.slice(eqIdx + 1).trim();

    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    if (key && !/\s/.test(key)) {
      results.push({ name: key, value });
    }
  }

  return results;
}

export function EnvVarsInput({
  initialVars,
  onSubmit,
  onSkip,
  disabled,
}: EnvVarsInputProps) {
  const [vars, setVars] = useState<EnvVar[]>(
    initialVars?.length ? initialVars : [{ name: "", value: "" }]
  );
  const [areValuesHidden, setAreValuesHidden] = useState(true);
  const [activeIndex, setActiveIndex] = useState<number | null>(null);
  const [pendingFocusIndex, setPendingFocusIndex] = useState<number | null>(null);
  const inputRefs = useRef<Array<HTMLInputElement | null>>([]);

  useEffect(() => {
    if (pendingFocusIndex !== null) {
      const el = inputRefs.current[pendingFocusIndex];
      if (el) {
        setTimeout(() => {
          el.focus();
        }, 0);
        setPendingFocusIndex(null);
      }
    }
  }, [pendingFocusIndex, vars]);

  const handlePaste = useCallback((e: React.ClipboardEvent) => {
    const text = e.clipboardData?.getData("text") ?? "";
    if (text && (/\n/.test(text) || /(=|:)\s*\S/.test(text))) {
      e.preventDefault();
      const items = parseEnvBlock(text);
      if (items.length > 0) {
        setVars((prev) => {
          const map = new Map(
            prev
              .filter((r) => r.name.trim().length > 0 || r.value.trim().length > 0)
              .map((r) => [r.name, r] as const)
          );
          for (const it of items) {
            if (!it.name) continue;
            const existing = map.get(it.name);
            if (existing) map.set(it.name, { ...existing, value: it.value });
            else map.set(it.name, { name: it.name, value: it.value });
          }
          const next = Array.from(map.values());
          next.push({ name: "", value: "" });
          setPendingFocusIndex(next.length - 1);
          return next;
        });
      }
    }
  }, []);

  const filteredVars = vars.filter((v) => v.name.trim().length > 0);

  return (
    <div className="bg-neutral-50 dark:bg-neutral-900/50 rounded-xl p-4 border border-neutral-200 dark:border-neutral-800">
      <div className="flex items-center justify-between mb-3">
        <span className="text-sm font-medium text-neutral-700 dark:text-neutral-300">
          Environment Variables
        </span>
        <button
          type="button"
          onClick={() => {
            setActiveIndex(null);
            setAreValuesHidden((prev) => !prev);
          }}
          className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-300 transition p-1"
          aria-label={areValuesHidden ? "Show values" : "Hide values"}
        >
          {areValuesHidden ? (
            <EyeOff className="h-4 w-4" />
          ) : (
            <Eye className="h-4 w-4" />
          )}
        </button>
      </div>

      <div className="space-y-2" onPasteCapture={handlePaste}>
        <div
          className="grid gap-2 text-xs text-neutral-500 items-center"
          style={{ gridTemplateColumns: "1fr 1.5fr 32px" }}
        >
          <span>Name</span>
          <span>Value</span>
          <span />
        </div>

        {vars.map((row, idx) => {
          const isEditingValue = activeIndex === idx;
          const shouldMask =
            areValuesHidden && row.value.trim().length > 0 && !isEditingValue;

          return (
            <div
              key={idx}
              className="grid gap-2 items-center"
              style={{ gridTemplateColumns: "1fr 1.5fr 32px" }}
            >
              <input
                type="text"
                value={row.name}
                disabled={disabled}
                ref={(el) => {
                  inputRefs.current[idx] = el;
                }}
                onChange={(e) =>
                  setVars((prev) => {
                    const next = [...prev];
                    if (next[idx]) next[idx] = { ...next[idx], name: e.target.value };
                    return next;
                  })
                }
                placeholder="API_KEY"
                className="w-full h-9 rounded-md border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-950 px-3 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-600 disabled:opacity-50"
              />
              <input
                type={shouldMask ? "password" : "text"}
                value={shouldMask ? MASKED_VALUE : row.value}
                disabled={disabled}
                onChange={
                  shouldMask
                    ? undefined
                    : (e) =>
                        setVars((prev) => {
                          const next = [...prev];
                          if (next[idx])
                            next[idx] = { ...next[idx], value: e.target.value };
                          return next;
                        })
                }
                onFocus={() => setActiveIndex(idx)}
                onBlur={() => setActiveIndex((cur) => (cur === idx ? null : cur))}
                readOnly={shouldMask}
                placeholder="sk-..."
                className="w-full h-9 rounded-md border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-950 px-3 text-sm font-mono text-neutral-900 dark:text-neutral-100 placeholder:text-neutral-400 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:focus:ring-neutral-600 disabled:opacity-50"
              />
              <button
                type="button"
                disabled={disabled || vars.length <= 1}
                onClick={() =>
                  setVars((prev) => {
                    const next = prev.filter((_, i) => i !== idx);
                    return next.length > 0 ? next : [{ name: "", value: "" }];
                  })
                }
                className={clsx(
                  "h-9 w-8 rounded-md border border-neutral-200 dark:border-neutral-700 text-neutral-500 dark:text-neutral-400 grid place-items-center",
                  disabled || vars.length <= 1
                    ? "opacity-50 cursor-not-allowed"
                    : "hover:bg-neutral-100 dark:hover:bg-neutral-800"
                )}
                aria-label="Remove"
              >
                <Minus className="w-3.5 h-3.5" />
              </button>
            </div>
          );
        })}

        <button
          type="button"
          onClick={() => setVars((prev) => [...prev, { name: "", value: "" }])}
          disabled={disabled}
          className="flex items-center gap-1.5 h-8 px-3 text-xs text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 transition disabled:opacity-50"
        >
          <Plus className="w-3.5 h-3.5" />
          Add variable
        </button>
      </div>

      <div className="flex items-center gap-2 text-xs text-neutral-400 mt-3 mb-4">
        <Upload className="h-3.5 w-3.5" />
        <span>Tip: Paste a .env file to auto-fill</span>
      </div>

      <div className="flex gap-2 pt-2 border-t border-neutral-200 dark:border-neutral-800">
        <button
          type="button"
          onClick={onSkip}
          disabled={disabled}
          className="flex-1 h-9 rounded-md border border-neutral-200 dark:border-neutral-700 text-sm text-neutral-600 dark:text-neutral-400 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition disabled:opacity-50"
        >
          Skip for now
        </button>
        <button
          type="button"
          onClick={() => onSubmit(filteredVars)}
          disabled={disabled}
          className="flex-1 h-9 rounded-md bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 text-sm font-medium hover:bg-neutral-800 dark:hover:bg-neutral-200 transition disabled:opacity-50"
        >
          {filteredVars.length > 0
            ? `Continue with ${filteredVars.length} variable${filteredVars.length === 1 ? "" : "s"}`
            : "Continue"}
        </button>
      </div>
    </div>
  );
}
