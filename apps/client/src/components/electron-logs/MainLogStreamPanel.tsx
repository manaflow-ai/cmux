import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import type { ElectronMainLogEntry } from "@/hooks/useElectronMainLogStream";
import { cn } from "@/lib/utils";

interface MainLogStreamPanelProps {
  entries: ElectronMainLogEntry[];
  onClear: () => void;
}

const LEVEL_CLASS: Record<ElectronMainLogEntry["level"], string> = {
  log: "text-emerald-300",
  warn: "text-amber-300",
  error: "text-red-300",
};

function formatTimestamp(ms: number): string {
  try {
    return new Date(ms).toLocaleTimeString();
  } catch {
    return "";
  }
}

export function MainLogStreamPanel({ entries, onClear }: MainLogStreamPanelProps) {
  return (
    <Card className="border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900/70">
      <CardHeader className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
        <div>
          <CardTitle className="text-lg text-neutral-900 dark:text-neutral-50">
            Main process stream
          </CardTitle>
          <CardDescription className="text-sm text-neutral-600 dark:text-neutral-400">
            Live feed mirrored from the Electron main process console.
          </CardDescription>
        </div>
        <Button
          variant="outline"
          size="sm"
          onClick={onClear}
          disabled={entries.length === 0}
          className="shrink-0"
        >
          Clear
        </Button>
      </CardHeader>
      <CardContent>
        <div className="rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-900 text-neutral-100 max-h-72 overflow-auto">
          {entries.length === 0 ? (
            <p className="p-4 text-xs text-neutral-300 dark:text-neutral-400">
              No log entries yet.
            </p>
          ) : (
            <ul className="divide-y divide-neutral-800/70">
              {entries.map((entry, index) => (
                <li
                  key={`${entry.receivedAt}-${index}`}
                  className="px-4 py-2 text-xs font-mono whitespace-pre-wrap break-words"
                >
                  <div className="flex flex-col gap-1 sm:flex-row sm:items-baseline sm:gap-3">
                    <span className="text-neutral-400 dark:text-neutral-500">
                      {formatTimestamp(entry.receivedAt)}
                    </span>
                    <span
                      className={cn(
                        "uppercase tracking-wide font-semibold",
                        LEVEL_CLASS[entry.level]
                      )}
                    >
                      {entry.level}
                    </span>
                    <span className="text-neutral-100 dark:text-neutral-100">
                      {entry.message}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
