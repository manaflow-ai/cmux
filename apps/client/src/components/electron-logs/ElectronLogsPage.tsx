import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { useElectronLogsQuery } from "@/hooks/useElectronLogsQuery";
import { useElectronMainLogStream } from "@/hooks/useElectronMainLogStream";
import { isElectron } from "@/lib/electron";
import { copyAllElectronLogs } from "@/lib/electron-logs/electron-logs";
import type { ElectronLogFile } from "@/lib/electron-logs/types";
import { cn } from "@/lib/utils";
import { ClipboardCopy, RefreshCcw } from "lucide-react";
import { useCallback, useMemo } from "react";
import { toast } from "sonner";

import { LogFileViewer } from "./LogFileViewer";
import { MainLogStreamPanel } from "./MainLogStreamPanel";

export function ElectronLogsPage() {
  const { entries, clear } = useElectronMainLogStream();
  const { data, isLoading, isError, error, refetch, isFetching } =
    useElectronLogsQuery();

  const files = useMemo<ElectronLogFile[]>(() => {
    if (!data?.files) return [];
    return [...data.files];
  }, [data]);

  const handleCopyAll = useCallback(async () => {
    const ok = await copyAllElectronLogs();
    if (ok) {
      toast.success("Copied logs to clipboard");
    } else {
      toast.error("Unable to copy logs");
    }
  }, []);

  const handleRefresh = useCallback(() => {
    void refetch();
  }, [refetch]);

  if (!isElectron) {
    return (
      <div className="px-6 py-10">
        <div className="mx-auto max-w-4xl">
          <Card className="border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900/70">
            <CardHeader>
              <CardTitle className="text-lg text-neutral-900 dark:text-neutral-50">
                Logs are only available in the desktop app
              </CardTitle>
              <CardDescription className="text-sm text-neutral-600 dark:text-neutral-400">
                Launch the Electron application to inspect local log files and
                the main process output.
              </CardDescription>
            </CardHeader>
          </Card>
        </div>
      </div>
    );
  }

  return (
    <div className="px-6 py-8 h-full overflow-y-auto">
      <div className="mx-auto flex w-full max-w-5xl flex-col gap-6">
        <header className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 className="text-2xl font-semibold text-neutral-900 dark:text-neutral-50">
              Logs
            </h1>
            <p className="text-sm text-neutral-600 dark:text-neutral-400">
              View the live main process stream and browse persisted log files.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={handleRefresh}
              disabled={isFetching}
            >
              <RefreshCcw
                className={cn(
                  "mr-2 h-4 w-4",
                  isFetching ? "animate-spin" : undefined
                )}
              />
              Refresh
            </Button>
            <Button size="sm" onClick={handleCopyAll}>
              <ClipboardCopy className="mr-2 h-4 w-4" />
              Copy all
            </Button>
          </div>
        </header>

        <MainLogStreamPanel entries={entries} onClear={clear} />

        <section className="space-y-4">
          {isLoading ? (
            <div className="space-y-3">
              <Skeleton className="h-6 w-48" />
              <Skeleton className="h-48 w-full" />
              <Skeleton className="h-48 w-full" />
            </div>
          ) : isError ? (
            <Card className="border-red-200 bg-red-50 dark:border-red-900/60 dark:bg-red-900/20">
              <CardHeader>
                <CardTitle className="text-base text-red-700 dark:text-red-200">
                  Failed to load log files
                </CardTitle>
                <CardDescription className="text-sm text-red-600 dark:text-red-300">
                  {error instanceof Error ? error.message : "Unknown error"}
                </CardDescription>
              </CardHeader>
              <CardContent>
                <Button variant="outline" size="sm" onClick={handleRefresh}>
                  Try again
                </Button>
              </CardContent>
            </Card>
          ) : files.length === 0 ? (
            <Card className="border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900/70">
              <CardHeader>
                <CardTitle className="text-base text-neutral-900 dark:text-neutral-50">
                  No log files detected
                </CardTitle>
                <CardDescription className="text-sm text-neutral-600 dark:text-neutral-400">
                  The Electron app has not written any log files yet. Trigger an
                  action and refresh to see new entries.
                </CardDescription>
              </CardHeader>
            </Card>
          ) : (
            files.map((file) => <LogFileViewer key={file.path} file={file} />)
          )}
        </section>
      </div>
    </div>
  );
}
