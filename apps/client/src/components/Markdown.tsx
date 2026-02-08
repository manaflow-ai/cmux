import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { Components } from "react-markdown";
import { useMemo } from "react";

import { cn } from "@/lib/utils";

type MarkdownSegment =
  | { kind: "markdown"; content: string }
  | { kind: "details"; summary: string; content: string };

function stripHtmlTags(input: string): string {
  return input.replace(/<[^>]*>/g, "");
}

function normalizeInlineHtml(content: string): string {
  let out = content;

  // Hide internal collapse markers used in our PR preview bot comments.
  out = out.replace(/<!--\s*cmux-preview-collapsed\s*-->/gi, "");

  // Convert HTML line breaks to newlines.
  out = out.replace(/<br\s*\/?>/gi, "\n");

  // Convert simple GitHub-style anchor tags to Markdown links.
  // Example:
  // <a href="https://example.com" target="_blank">Open</a> -> [Open](https://example.com)
  out = out.replace(
    /<a\s+[^>]*href=(?:"([^"]+)"|'([^']+)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi,
    (_match, href1: string | undefined, href2: string | undefined, href3: string | undefined, inner: string) => {
      const href = String(href1 ?? href2 ?? href3 ?? "").trim();
      const text = stripHtmlTags(String(inner ?? "")).replace(/\s+/g, " ").trim();
      if (!href) {
        return text || "";
      }
      const label = text || href;
      return `[${label}](${href})`;
    },
  );

  return out;
}

function splitDetailsBlocks(content: string): MarkdownSegment[] {
  const segments: MarkdownSegment[] = [];
  const re =
    /<details\b[^>]*>\s*<summary\b[^>]*>([\s\S]*?)<\/summary>\s*([\s\S]*?)<\/details>/gi;

  let lastIndex = 0;
  let match: RegExpExecArray | null = null;
  while ((match = re.exec(content)) !== null) {
    const matchIndex = match.index ?? 0;
    if (matchIndex > lastIndex) {
      const before = content.slice(lastIndex, matchIndex);
      if (before.trim().length > 0) {
        segments.push({ kind: "markdown", content: before });
      }
    }

    const summaryRaw = match[1] ?? "";
    const innerRaw = match[2] ?? "";
    const summary = stripHtmlTags(summaryRaw).replace(/\s+/g, " ").trim();
    segments.push({
      kind: "details",
      summary: summary || "Details",
      content: innerRaw.trim(),
    });

    lastIndex = matchIndex + match[0].length;
  }

  if (lastIndex < content.length) {
    const rest = content.slice(lastIndex);
    if (rest.trim().length > 0) {
      segments.push({ kind: "markdown", content: rest });
    }
  }

  if (segments.length === 0) {
    return [{ kind: "markdown", content }];
  }

  return segments;
}

const markdownComponents: Components = {
  a: ({ node: _node, href, children, ...props }) => {
    return (
      <a
        href={href}
        target="_blank"
        rel="noreferrer"
        {...props}
      >
        {children}
      </a>
    );
  },
};

export function Markdown({
  content,
  className,
}: {
  content: string;
  className?: string;
}) {
  const normalized = useMemo(() => normalizeInlineHtml(content), [content]);
  const segments = useMemo(
    () => splitDetailsBlocks(normalized),
    [normalized],
  );

  return (
    <div
      className={cn(
        "prose prose-neutral dark:prose-invert prose-sm max-w-none",
        "prose-p:my-1.5 prose-p:leading-relaxed",
        "prose-headings:mt-4 prose-headings:mb-3 prose-headings:font-semibold",
        "prose-h1:text-xl prose-h1:mt-5 prose-h1:mb-3",
        "prose-h2:text-lg prose-h2:mt-4 prose-h2:mb-2.5",
        "prose-h3:text-base prose-h3:mt-3.5 prose-h3:mb-2",
        "prose-ul:my-2 prose-ul:list-disc prose-ul:pl-5",
        "prose-ol:my-2 prose-ol:list-decimal prose-ol:pl-5",
        "prose-li:my-0.5",
        "prose-blockquote:border-l-4 prose-blockquote:border-neutral-300 dark:prose-blockquote:border-neutral-600",
        "prose-blockquote:pl-4 prose-blockquote:py-0.5 prose-blockquote:my-2",
        "prose-code:px-1.5 prose-code:py-0.5 prose-code:rounded prose-code:bg-neutral-200 dark:prose-code:bg-neutral-700",
        "prose-code:text-[13px] prose-code:font-mono prose-code:before:content-none prose-code:after:content-none",
        "prose-pre:bg-neutral-900 dark:prose-pre:bg-neutral-800 prose-pre:text-neutral-100",
        "prose-pre:p-3 prose-pre:rounded-md prose-pre:my-2 prose-pre:overflow-x-auto",
        "prose-a:text-blue-600 dark:prose-a:text-blue-400 prose-a:underline prose-a:break-words",
        "prose-table:my-2 prose-table:border prose-table:border-neutral-300 dark:prose-table:border-neutral-600",
        "prose-th:p-2 prose-th:bg-neutral-100 dark:prose-th:bg-neutral-800",
        "prose-td:p-2 prose-td:border prose-td:border-neutral-300 dark:prose-td:border-neutral-600",
        "prose-hr:my-3 prose-hr:border-neutral-300 dark:prose-hr:border-neutral-600",
        className,
      )}
    >
      {segments.map((segment, idx) => {
        if (segment.kind === "details") {
          return (
            <details
              key={`details:${idx}`}
              className="my-2 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50/40 dark:bg-neutral-950/30 px-3 py-2"
            >
              <summary className="cursor-pointer select-none text-[13px] font-medium text-neutral-700 dark:text-neutral-300">
                {segment.summary}
              </summary>
              <div className="mt-2">
                <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
                  {segment.content}
                </ReactMarkdown>
              </div>
            </details>
          );
        }
        return (
          <ReactMarkdown
            key={`md:${idx}`}
            remarkPlugins={[remarkGfm]}
            components={markdownComponents}
          >
            {segment.content}
          </ReactMarkdown>
        );
      })}
    </div>
  );
}

export default Markdown;
