import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { useQuery } from "convex/react";
import { useAction } from "convex/react";
import { useState, useCallback } from "react";
import {
  ChevronRight,
  Code2,
  Image as ImageIcon,
  Loader2,
  RefreshCw,
  Sparkles,
} from "lucide-react";
import clsx from "clsx";

interface ClaimEvidence {
  type: "image" | "video" | "codeDiff";
  screenshotIndex?: number;
  imageUrl?: string;
  filePath?: string;
  startLine?: number;
  endLine?: number;
  summary?: string;
  patch?: string;
}

interface Claim {
  claim: string;
  evidence: ClaimEvidence;
  timestamp?: number;
}

interface ClaimsBoardProps {
  task: Doc<"tasks"> | null;
  runId: Id<"taskRuns"> | null;
  teamSlugOrId: string;
  taskPrompt: string;
  gitDiff: string;
  screenshots: Array<{ url: string; description?: string }>;
}

const DIFF_HEADER_PREFIXES = [
  "diff --git ",
  "index ",
  "--- ",
  "+++ ",
  "new file mode ",
  "deleted file mode ",
  "similarity index ",
  "rename from ",
  "rename to ",
  "old mode ",
  "new mode ",
  "copy from ",
  "copy to ",
];

const HUNK_HEADER_REGEX = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

type LineRange = {
  start: number;
  end: number;
};

type RenderLine = {
  text: string;
  kind: "commentary" | "diff";
};

function normalizeLineRange(
  startLine?: number,
  endLine?: number,
): LineRange | null {
  const startValue =
    typeof startLine === "number" ? startLine : endLine;
  const endValue = typeof endLine === "number" ? endLine : startLine;

  if (
    typeof startValue !== "number" ||
    typeof endValue !== "number"
  ) {
    return null;
  }

  if (!Number.isFinite(startValue) || !Number.isFinite(endValue)) {
    return null;
  }

  const min = Math.min(startValue, endValue);
  const max = Math.max(startValue, endValue);

  if (min <= 0 || max <= 0) {
    return null;
  }

  return { start: min, end: max };
}

function stripDiffHeaders(diffText: string): string {
  const normalized = diffText.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  const filtered = lines.filter(
    (line) =>
      !DIFF_HEADER_PREFIXES.some((prefix) => line.startsWith(prefix)),
  );
  while (filtered.length > 0 && filtered[filtered.length - 1] === "") {
    filtered.pop();
  }
  return filtered.join("\n");
}

function extractFileDiff(diffText: string, filePath?: string): string | null {
  if (!diffText || !filePath) {
    return null;
  }

  const normalized = diffText.replace(/\r\n/g, "\n");
  const lines = normalized.split("\n");
  const targetA = ` a/${filePath}`;
  const targetB = ` b/${filePath}`;

  let current: string[] = [];
  let isTarget = false;

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      if (isTarget && current.length > 0) {
        return current.join("\n");
      }
      current = [line];
      isTarget =
        line.includes(targetA) || line.includes(targetB);
      continue;
    }

    if (current.length > 0) {
      current.push(line);
    }
  }

  if (isTarget && current.length > 0) {
    return current.join("\n");
  }

  return null;
}

function isInRange(value: number, range: LineRange): boolean {
  return value >= range.start && value <= range.end;
}

function extractRelevantHunks(
  fileDiff: string,
  lineRange: LineRange | null,
): string {
  if (!fileDiff) {
    return "";
  }

  if (!lineRange) {
    return stripDiffHeaders(fileDiff);
  }

  const lines = fileDiff.replace(/\r\n/g, "\n").split("\n");
  const output: string[] = [];
  let currentHunk: string[] = [];
  let oldLine = 0;
  let newLine = 0;
  let hunkMatches = false;

  const flushHunk = () => {
    if (hunkMatches && currentHunk.length > 0) {
      output.push(...currentHunk);
    }
  };

  for (const line of lines) {
    if (DIFF_HEADER_PREFIXES.some((prefix) => line.startsWith(prefix))) {
      continue;
    }

    if (line.startsWith("@@")) {
      flushHunk();
      currentHunk = [line];
      hunkMatches = false;
      const match = line.match(HUNK_HEADER_REGEX);
      if (match) {
        oldLine = Number.parseInt(match[1], 10);
        newLine = Number.parseInt(match[3], 10);
      } else {
        oldLine = 0;
        newLine = 0;
      }
      continue;
    }

    if (currentHunk.length === 0) {
      continue;
    }

    currentHunk.push(line);

    if (line.startsWith("\\")) {
      continue;
    }

    if (line.startsWith("+") && !line.startsWith("+++")) {
      if (isInRange(newLine, lineRange)) {
        hunkMatches = true;
      }
      newLine += 1;
      continue;
    }

    if (line.startsWith("-") && !line.startsWith("---")) {
      if (isInRange(oldLine, lineRange)) {
        hunkMatches = true;
      }
      oldLine += 1;
      continue;
    }

    if (isInRange(oldLine, lineRange) || isInRange(newLine, lineRange)) {
      hunkMatches = true;
    }
    oldLine += 1;
    newLine += 1;
  }

  flushHunk();

  const outputText = output.join("\n");
  if (outputText) {
    return outputText;
  }

  return stripDiffHeaders(fileDiff);
}

export function ClaimsBoard({
  task: _task,
  runId,
  teamSlugOrId,
  taskPrompt,
  gitDiff,
  screenshots,
}: ClaimsBoardProps) {
  const [selectedClaimIndex, setSelectedClaimIndex] = useState<number | null>(null);
  const [isGenerating, setIsGenerating] = useState(false);

  // Query for existing claims
  const claimsData = useQuery(
    api.claimsQueries.getClaimsForRun,
    runId ? { teamSlugOrId, runId } : "skip"
  );

  // Action to generate claims
  const generateClaims = useAction(api.claims.generateClaims);

  const handleGenerateClaims = useCallback(async () => {
    if (!runId) return;

    setIsGenerating(true);
    try {
      await generateClaims({
        runId,
        taskPrompt,
        gitDiff,
        screenshotCount: screenshots.length,
        screenshotDescriptions: screenshots.map((s) => s.description ?? "Screenshot"),
      });
    } catch (error) {
      console.error("[ClaimsBoard] Failed to generate claims:", error);
    } finally {
      setIsGenerating(false);
    }
  }, [runId, taskPrompt, gitDiff, screenshots, generateClaims]);

  const claims = claimsData?.claims as Claim[] | null;
  const selectedClaim = selectedClaimIndex !== null ? claims?.[selectedClaimIndex] : null;

  // If claims are being loaded or generated automatically
  if (claimsData === undefined) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4 p-4">
        <Loader2 className="size-8 text-neutral-400 animate-spin" />
        <div className="text-center">
          <p className="text-sm font-medium text-neutral-700 dark:text-neutral-200">
            Loading Claims...
          </p>
        </div>
      </div>
    );
  }

  // If no claims yet, show waiting/generate UI
  if (!claims || claims.length === 0) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4 p-4">
        {isGenerating ? (
          <Loader2 className="size-8 text-blue-500 animate-spin" />
        ) : (
          <Sparkles className="size-8 text-neutral-400" />
        )}
        <div className="text-center">
          <p className="text-sm font-medium text-neutral-700 dark:text-neutral-200">
            {isGenerating ? "Generating Claims..." : "Claims Board"}
          </p>
          <p className="mt-1 text-xs text-neutral-500 dark:text-neutral-400">
            {isGenerating
              ? "AI is analyzing the task results and creating claims with evidence"
              : "Claims are generated automatically after screenshot collection completes"}
          </p>
        </div>
        {!isGenerating && (
          <button
            type="button"
            onClick={handleGenerateClaims}
            disabled={!runId}
            className={clsx(
              "flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors",
              "bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
            )}
          >
            <Sparkles className="size-4" />
            Generate Claims Now
          </button>
        )}
      </div>
    );
  }

  return (
    <div className="flex h-full">
      {/* Left side: Claims list */}
      <div className="w-1/2 border-r border-neutral-200 dark:border-neutral-800 overflow-y-auto">
        <div className="flex items-center justify-between px-3 py-2 border-b border-neutral-200 dark:border-neutral-800">
          <span className="text-xs font-medium text-neutral-600 dark:text-neutral-300">
            Claims ({claims.length})
          </span>
          <button
            type="button"
            onClick={handleGenerateClaims}
            disabled={isGenerating}
            className="p-1 rounded hover:bg-neutral-100 dark:hover:bg-neutral-800 text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300 transition-colors"
            title="Regenerate claims"
          >
            <RefreshCw className={clsx("size-3.5", isGenerating && "animate-spin")} />
          </button>
        </div>
        <div className="divide-y divide-neutral-100 dark:divide-neutral-800">
          {claims.map((claim, index) => (
            <button
              key={index}
              type="button"
              onClick={() => setSelectedClaimIndex(index)}
              className={clsx(
                "w-full text-left px-3 py-2.5 transition-colors",
                selectedClaimIndex === index
                  ? "bg-blue-50 dark:bg-blue-900/20"
                  : "hover:bg-neutral-50 dark:hover:bg-neutral-900/50"
              )}
            >
              <div className="flex items-start gap-2">
                <div className="mt-0.5 shrink-0">
                  {claim.evidence.type === "image" ? (
                    <ImageIcon className="size-3.5 text-green-600 dark:text-green-400" />
                  ) : (
                    <Code2 className="size-3.5 text-blue-600 dark:text-blue-400" />
                  )}
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-xs text-neutral-800 dark:text-neutral-200 line-clamp-2">
                    {claim.claim}
                  </p>
                  {claim.evidence.type === "codeDiff" && claim.evidence.filePath && (
                    <p className="mt-0.5 text-[10px] font-mono text-neutral-500 dark:text-neutral-400 truncate">
                      {claim.evidence.filePath}
                    </p>
                  )}
                </div>
                <ChevronRight
                  className={clsx(
                    "size-3.5 shrink-0 transition-transform",
                    selectedClaimIndex === index
                      ? "text-blue-600 dark:text-blue-400"
                      : "text-neutral-300 dark:text-neutral-600"
                  )}
                />
              </div>
            </button>
          ))}
        </div>
      </div>

      {/* Right side: Evidence viewer */}
      <div className="w-1/2 overflow-y-auto bg-neutral-50 dark:bg-neutral-950">
        {selectedClaim ? (
          <EvidenceViewer
            claim={selectedClaim}
            screenshots={screenshots}
            gitDiff={gitDiff}
          />
        ) : (
          <div className="flex h-full items-center justify-center text-neutral-400">
            <p className="text-xs">Select a claim to view evidence</p>
          </div>
        )}
      </div>
    </div>
  );
}

interface EvidenceViewerProps {
  claim: Claim;
  screenshots: Array<{ url: string; description?: string }>;
  gitDiff: string;
}

function EvidenceViewer({ claim, screenshots, gitDiff }: EvidenceViewerProps) {
  const { evidence } = claim;

  if (evidence.type === "image") {
    const screenshotIndex = evidence.screenshotIndex ?? 0;
    const screenshot = screenshots[screenshotIndex];

    if (!screenshot) {
      return (
        <div className="flex h-full items-center justify-center p-4 text-neutral-400">
          <p className="text-xs">Screenshot not available</p>
        </div>
      );
    }

    return (
      <div className="p-3">
        <div className="mb-2">
          <p className="text-xs text-neutral-600 dark:text-neutral-400">
            Screenshot {screenshotIndex + 1}
          </p>
        </div>
        <img
          src={screenshot.url}
          alt={`Evidence for: ${claim.claim}`}
          className="w-full rounded-lg border border-neutral-200 dark:border-neutral-800"
        />
      </div>
    );
  }

  if (evidence.type === "codeDiff") {
    // Extract relevant diff for this file
    const filePath = evidence.filePath;
    const lineRange = normalizeLineRange(evidence.startLine, evidence.endLine);
    const patchText = evidence.patch?.trim() ?? "";
    let relevantDiff = "";

    if (patchText) {
      relevantDiff = stripDiffHeaders(patchText);
    } else if (filePath && gitDiff) {
      const fileDiff = extractFileDiff(gitDiff, filePath);
      if (fileDiff) {
        relevantDiff = extractRelevantHunks(fileDiff, lineRange);
      }
    }

    const summary = evidence.summary?.trim();
    const diffLines = relevantDiff ? relevantDiff.split("\n") : [];
    const renderedLines: RenderLine[] = [];

    if (summary) {
      renderedLines.push({ text: `// ${summary}`, kind: "commentary" });
    }

    if (diffLines.length > 0) {
      for (const line of diffLines) {
        renderedLines.push({ text: line, kind: "diff" });
      }
    } else {
      renderedLines.push({
        text: "No diff snippet available",
        kind: "diff",
      });
    }

    return (
      <div className="p-3">
        <div className="mb-2 flex items-center gap-2">
          <Code2 className="size-3.5 text-blue-600 dark:text-blue-400" />
          <code className="text-xs font-mono text-neutral-700 dark:text-neutral-300">
            {filePath || "Code changes"}
          </code>
        </div>
        <pre className="overflow-x-auto rounded-lg bg-neutral-900 p-3 text-xs">
          <code className="font-mono text-neutral-100">
            {renderedLines.map((line, index) => (
              <span
                key={`${line.kind}-${index}`}
                className={clsx(
                  "block whitespace-pre-wrap break-all",
                  line.kind === "commentary" &&
                    "text-amber-300 dark:text-amber-200 italic"
                )}
              >
                {line.text}
              </span>
            ))}
          </code>
        </pre>
      </div>
    );
  }

  return (
    <div className="flex h-full items-center justify-center p-4 text-neutral-400">
      <p className="text-xs">Evidence type not supported</p>
    </div>
  );
}
