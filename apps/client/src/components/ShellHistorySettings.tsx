import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { Switch } from "@heroui/react";
import { useClipboard } from "@mantine/hooks";
import { useMutation, useQuery } from "@tanstack/react-query";
import { useConvex } from "convex/react";
import { Check, Copy } from "lucide-react";
import { useEffect, useState } from "react";
import { toast } from "sonner";

interface ShellHistorySettingsProps {
  teamSlugOrId: string;
  onDataChange?: (data: { enabled: boolean; sanitizedHistory: string }) => void;
}

// Detect OS for clipboard command
function getOsType(): "mac" | "windows" | "linux" {
  const platform = navigator.platform.toLowerCase();
  if (platform.includes("mac")) return "mac";
  if (platform.includes("win")) return "windows";
  return "linux";
}

function getClipboardCommand(): string {
  const filter = `grep -v -E '(password|passwd|pwd=|token|api_key|apikey|secret|credential|Bearer|curl.*-u|curl.*-H.*[Aa]uthorization|mysql.*-p|psql.*password|\\b[A-Z_]{5,}\\b)'`;

  const os = getOsType();
  if (os === "mac") {
    return `cat ~/.zsh_history | ${filter} | pbcopy`;
  }
  if (os === "windows") {
    return `cat ~/.zsh_history | ${filter} | clip`;
  }
  return `cat ~/.zsh_history | ${filter} | xclip -selection clipboard`;
}

export function ShellHistorySettings({
  teamSlugOrId,
  onDataChange,
}: ShellHistorySettingsProps) {
  const convex = useConvex();
  const clipboard = useClipboard({ timeout: 2000 });
  const [enabled, setEnabled] = useState(false);
  const [originalEnabled, setOriginalEnabled] = useState(false);
  const [sanitizedHistory, setSanitizedHistory] = useState("");
  const [originalSanitizedHistory, setOriginalSanitizedHistory] = useState("");

  // Query existing settings
  const { data: settings } = useQuery(
    convexQuery(api.shellHistorySettings.get, { teamSlugOrId }),
  );

  // Mutation for saving settings
  const updateMutation = useMutation({
    mutationFn: async (data: {
      enabled: boolean;
      sanitizedHistory?: string;
    }) => {
      return await convex.mutation(api.shellHistorySettings.update, {
        teamSlugOrId,
        ...data,
      });
    },
    onSuccess: () => {
      setOriginalEnabled(enabled);
      setOriginalSanitizedHistory(sanitizedHistory);
      toast.success("Shell history settings saved");
    },
    onError: (error) => {
      toast.error("Failed to save shell history settings");
      console.error("Error saving shell history settings:", error);
    },
  });

  // Initialize form values when data loads
  useEffect(() => {
    if (settings !== undefined) {
      setEnabled(settings.enabled ?? false);
      setOriginalEnabled(settings.enabled ?? false);
      setSanitizedHistory(settings.sanitizedHistory ?? "");
      setOriginalSanitizedHistory(settings.sanitizedHistory ?? "");
    }
  }, [settings]);

  // Notify parent of changes
  useEffect(() => {
    onDataChange?.({ enabled, sanitizedHistory });
  }, [enabled, sanitizedHistory, onDataChange]);

  const hasChanges = () => {
    return (
      enabled !== originalEnabled ||
      sanitizedHistory !== originalSanitizedHistory
    );
  };

  const saveSettings = () => {
    updateMutation.mutate({
      enabled,
      sanitizedHistory: sanitizedHistory || undefined,
    });
  };

  const lineCount = sanitizedHistory
    ? sanitizedHistory.split("\n").filter((line) => line.trim()).length
    : 0;

  return (
    <div className="bg-white dark:bg-neutral-950 rounded-lg border border-neutral-200 dark:border-neutral-800">
      <div className="px-4 py-3 border-b border-neutral-200 dark:border-neutral-800">
        <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
          Shell History
        </h2>
      </div>
      <div className="p-4 space-y-4">
        {/* Toggle */}
        <div className="flex items-start justify-between gap-4">
          <div>
            <label className="block text-sm font-medium text-neutral-900 dark:text-neutral-100">
              Seed Default Shell History
            </label>
            <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
              Pre-populate VMs with your shell history for zsh-autosuggestions.
            </p>
          </div>
          <Switch
            aria-label="Seed Default Shell History"
            size="sm"
            color="primary"
            isSelected={enabled}
            onValueChange={setEnabled}
          />
        </div>

        {/* Explanation */}
        <div className="p-3 bg-neutral-50 dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-800 rounded-lg">
          <h4 className="text-xs font-medium text-neutral-900 dark:text-neutral-100 mb-2">
            What is zsh-autosuggestions?
          </h4>
          <p className="text-xs text-neutral-600 dark:text-neutral-400 mb-2">
            Zsh-autosuggestions suggests commands as you type based on your
            command history. Enable this to seed VMs with a sanitized version of
            your local shell history, giving you familiar command suggestions.
          </p>
          <h4 className="text-xs font-medium text-neutral-900 dark:text-neutral-100 mb-1 mt-3">
            What gets filtered out?
          </h4>
          <ul className="text-xs text-neutral-600 dark:text-neutral-400 list-disc ml-4 space-y-0.5">
            <li>Environment variables (uppercase words like API_KEY, SECRET_TOKEN)</li>
            <li>Passwords and credentials</li>
            <li>Auth tokens and Bearer headers</li>
            <li>Database connection strings with passwords</li>
          </ul>
        </div>

        {/* Command to copy */}
        {enabled && (
          <>
            <div>
              <label className="block text-xs font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                Step 1: Run this command in your terminal to copy sanitized history
              </label>
              <div className="flex items-start gap-2">
                <div className="flex-1 p-2 bg-neutral-100 dark:bg-neutral-800 rounded-lg font-mono text-xs text-neutral-800 dark:text-neutral-200 break-all">
                  {getClipboardCommand()}
                </div>
                <button
                  type="button"
                  onClick={() => clipboard.copy(getClipboardCommand())}
                  className="p-2 text-neutral-500 hover:text-neutral-700 dark:text-neutral-400 dark:hover:text-neutral-200 hover:bg-neutral-200 dark:hover:bg-neutral-700 rounded-lg transition-colors flex-shrink-0"
                  title={clipboard.copied ? "Copied!" : "Copy command"}
                >
                  {clipboard.copied ? (
                    <Check className="w-4 h-4 text-green-500" />
                  ) : (
                    <Copy className="w-4 h-4" />
                  )}
                </button>
              </div>
            </div>

            {/* Textarea for pasting */}
            <div>
              <label className="block text-xs font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                Step 2: Paste your sanitized history here
              </label>
              <textarea
                value={sanitizedHistory}
                onChange={(e) => setSanitizedHistory(e.target.value)}
                placeholder="Paste your sanitized history here..."
                className="w-full h-40 px-3 py-2 border border-neutral-300 dark:border-neutral-700 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 font-mono text-xs resize-y"
              />
              <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
                {lineCount > 0 ? `${lineCount.toLocaleString()} lines` : "No history pasted yet"}
              </p>
            </div>
          </>
        )}
      </div>

      {/* Footer with save button */}
      <div className="px-4 py-3 border-t border-neutral-200 dark:border-neutral-800 flex items-center justify-end">
        <button
          onClick={saveSettings}
          disabled={!hasChanges() || updateMutation.isPending}
          className={`px-3 py-1.5 text-sm rounded-md transition-colors ${
            !hasChanges() || updateMutation.isPending
              ? "bg-neutral-200 dark:bg-neutral-800 text-neutral-400 dark:text-neutral-500 cursor-not-allowed"
              : "bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900 hover:bg-neutral-800 dark:hover:bg-neutral-200"
          }`}
        >
          {updateMutation.isPending ? "Saving..." : "Save"}
        </button>
      </div>
    </div>
  );
}
