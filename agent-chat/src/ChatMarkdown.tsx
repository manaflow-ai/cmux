import { memo, useEffect, useMemo, useState, type ReactNode } from "react";
import ReactMarkdown, { defaultUrlTransform, type Components } from "react-markdown";
import rehypeSanitize, { defaultSchema } from "rehype-sanitize";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import type { HighlighterCore, LanguageRegistration } from "shiki/core";
import { CopyIcon } from "./components/icons";

const langs = ["ts", "tsx", "js", "json", "bash", "shell", "python", "swift", "rust", "go", "html", "css", "markdown", "yaml", "diff"];
const themeName = "agent-css-variables";
let highlighterPromise: Promise<HighlighterCore> | null = null;
let reportedHighlighterFailure = false;
const htmlCache = new Map<string, { html: string; bytes: number }>();
const HTML_CACHE_MAX_BYTES = 900_000;
let htmlCacheBytes = 0;

function cacheEntryBytes(key: string, html: string) {
  return new TextEncoder().encode(key).byteLength + new TextEncoder().encode(html).byteLength;
}

function cachedHtml(key: string): string | null {
  const hit = htmlCache.get(key);
  if (hit === undefined) return null;
  htmlCache.delete(key);
  htmlCache.set(key, hit);
  return hit.html;
}

function cacheHtml(key: string, html: string) {
  const existing = htmlCache.get(key);
  if (existing) htmlCacheBytes -= existing.bytes;
  const bytes = cacheEntryBytes(key, html);
  htmlCache.set(key, { html, bytes });
  htmlCacheBytes += bytes;
  while (htmlCacheBytes > HTML_CACHE_MAX_BYTES) {
    const oldest = htmlCache.keys().next().value;
    if (oldest === undefined) break;
    htmlCacheBytes -= htmlCache.get(oldest)?.bytes ?? 0;
    htmlCache.delete(oldest);
  }
}

export function htmlCacheSizeForTest(): number {
  return htmlCache.size;
}

export function htmlCacheBytesForTest(): number {
  return htmlCacheBytes;
}

export function clearHtmlCacheForTest() {
  htmlCache.clear();
  htmlCacheBytes = 0;
}

export function cacheHtmlForTest(key: string, html: string) {
  cacheHtml(key, html);
}

function normalizeLang(registration: unknown): LanguageRegistration[] {
  return (Array.isArray(registration) ? registration : [registration]) as LanguageRegistration[];
}

function highlighter() {
  highlighterPromise ??= (async () => {
    const [
      core,
      engine,
      ts,
      tsx,
      js,
      json,
      bash,
      shell,
      python,
      swift,
      rust,
      go,
      html,
      css,
      markdown,
      yaml,
      diff,
    ] = await Promise.all([
      import("shiki/core"),
      import("shiki/engine/javascript"),
      import("shiki/langs/ts.mjs"),
      import("shiki/langs/tsx.mjs"),
      import("shiki/langs/js.mjs"),
      import("shiki/langs/json.mjs"),
      import("shiki/langs/bash.mjs"),
      import("shiki/langs/shell.mjs"),
      import("shiki/langs/python.mjs"),
      import("shiki/langs/swift.mjs"),
      import("shiki/langs/rust.mjs"),
      import("shiki/langs/go.mjs"),
      import("shiki/langs/html.mjs"),
      import("shiki/langs/css.mjs"),
      import("shiki/langs/markdown.mjs"),
      import("shiki/langs/yaml.mjs"),
      import("shiki/langs/diff.mjs"),
    ]);
    const registrations = [ts, tsx, js, json, bash, shell, python, swift, rust, go, html, css, markdown, yaml, diff]
      .flatMap((m) => normalizeLang(m.default));
    return core.createHighlighterCore({
      engine: engine.createJavaScriptRegexEngine(),
      themes: [core.createCssVariablesTheme({ name: themeName })],
      langs: registrations,
    });
  })();
  return highlighterPromise;
}

export async function highlightCode(code: string, lang = "text"): Promise<string> {
  const key = `${lang}\0${code}`;
  const cached = cachedHtml(key);
  if (cached) return cached;
  try {
    const h = await highlighter();
    const html = h.codeToHtml(code, { lang: langs.includes(lang) ? lang : "text", theme: themeName });
    cacheHtml(key, html);
    return html;
  } catch (err) {
    if (!reportedHighlighterFailure) {
      reportedHighlighterFailure = true;
      console.error("[agent-chat] syntax highlighter failed; falling back to plain text", err);
    }
    throw err;
  }
}

function textOf(node: ReactNode): string {
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (node && typeof node === "object" && "props" in node) return textOf((node as { props?: { children?: ReactNode } }).props?.children);
  return "";
}

function languageOf(className: unknown): string {
  const match = typeof className === "string" ? /language-([^\s]+)/.exec(className) : null;
  const raw = (match?.[1] ?? "text").toLowerCase();
  if (raw === "sh" || raw === "zsh") return "bash";
  if (raw === "yml") return "yaml";
  if (raw === "typescript") return "ts";
  if (raw === "javascript") return "js";
  return langs.includes(raw) ? raw : "text";
}

export function MarkdownCodeBlock({ code, lang = "text", streaming = false }: { code: string; lang?: string; streaming?: boolean }) {
  const [html, setHtml] = useState<string | null>(() => streaming ? null : cachedHtml(`${lang}\0${code}`));
  useEffect(() => {
    let cancelled = false;
    const key = `${lang}\0${code}`;
    if (streaming) {
      setHtml(null);
      return () => { cancelled = true; };
    }
    const cached = cachedHtml(key);
    if (cached) {
      setHtml(cached);
      return;
    }
    setHtml(null);
    highlightCode(code, lang)
      .then((next) => {
        cacheHtml(key, next);
        if (!cancelled) setHtml(next);
      })
      .catch(() => {
        if (!cancelled) setHtml(null);
      });
    return () => { cancelled = true; };
  }, [code, lang, streaming]);
  const copy = () => navigator.clipboard?.writeText(code).catch(() => {});
  return (
    <div className="markdown-code selectable">
      <div className="code-header">
        <span className="code-lang">{lang}</span>
        <button type="button" className="code-copy" aria-label="Copy code" onClick={copy}><CopyIcon /></button>
      </div>
      {html ? <div dangerouslySetInnerHTML={{ __html: html }} /> : <pre><code>{code}</code></pre>}
    </div>
  );
}

const schema = {
  ...defaultSchema,
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), "className"],
  },
};

function markdownComponents(streaming: boolean): Components {
  return {
  a({ href, children }) {
    const safeHref = defaultUrlTransform(href ?? "");
    return <a href={safeHref} target="_blank" rel="noopener noreferrer">{children}</a>;
  },
  pre({ children }) {
    const child = Array.isArray(children) ? children[0] : children;
    const props = child && typeof child === "object" && "props" in child ? (child as { props?: { children?: ReactNode; className?: unknown } }).props : undefined;
    const code = textOf(props?.children).replace(/\n$/, "");
    const lang = languageOf(props?.className);
    return <MarkdownCodeBlock code={code} lang={lang} streaming={streaming} />;
  },
  code({ children, className }) {
    if (className) return <code className={className}>{children}</code>;
    return <code>{children}</code>;
  },
  table({ children }) {
    return <div className="markdown-table-wrap"><table>{children}</table></div>;
  },
  };
}

export const ChatMarkdown = memo(function ChatMarkdown({ text, streaming = false }: { text: string; streaming?: boolean }) {
  const components = useMemo(() => markdownComponents(streaming), [streaming]);
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm, remarkBreaks]}
      rehypePlugins={[[rehypeSanitize, schema]]}
      components={components}
    >
      {text}
    </ReactMarkdown>
  );
});
