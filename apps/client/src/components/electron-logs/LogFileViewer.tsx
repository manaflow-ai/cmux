import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import type { ElectronLogFile } from "@/lib/electron-logs/types";

interface LogFileViewerProps {
  file: ElectronLogFile;
}

function formatBytes(size: number): string {
  if (!Number.isFinite(size) || size < 0) return "";
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function formatModified(modifiedMs: number | null): string {
  if (!modifiedMs) return "Unknown";
  try {
    return new Date(modifiedMs).toLocaleString();
  } catch {
    return "Unknown";
  }
}

export function LogFileViewer({ file }: LogFileViewerProps) {
  const hasContent = file.content.trim().length > 0;

  return (
    <Card className="border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900/70">
      <CardHeader className="space-y-1">
        <CardTitle className="text-base text-neutral-900 dark:text-neutral-50">
          {file.name}
        </CardTitle>
        <CardDescription className="text-sm text-neutral-600 dark:text-neutral-400">
          {file.path}
        </CardDescription>
        <CardDescription className="text-xs text-neutral-500 dark:text-neutral-500">
          Size: {formatBytes(file.size)} · Last modified: {formatModified(file.modifiedMs)}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <div className="rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-950/40 max-h-96 overflow-auto">
          {hasContent ? (
            <pre className="whitespace-pre-wrap break-words font-mono text-xs leading-relaxed text-neutral-800 dark:text-neutral-100 p-4">
              {file.content}
            </pre>
          ) : (
            <p className="p-4 text-xs text-neutral-500 dark:text-neutral-400">
              File is empty.
            </p>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
