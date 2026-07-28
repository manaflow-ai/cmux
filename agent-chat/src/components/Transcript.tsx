import { Popover } from "@base-ui-components/react/popover";
import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import type { Block, ChangedFile, SessionActions } from "../session";
import { fileDiffCacheKey } from "../session";
import { activityIndicatorState, activityTailKey } from "../activity";
import { ChatMarkdown, MarkdownCodeBlock } from "../ChatMarkdown";
import { useActivityStartedAt, useTicker } from "../hooks/useTicker";
import { useVirtualTurns } from "../hooks/useVirtualTurns";
import { Check, Chevron, CopyIcon, EllipsisIcon, PinwheelSpinner } from "./icons";
import { HintTooltip } from "./Tooltips";
import { activityRowLabel, groupTurns, summarizeTurnActivity, type TurnGroup } from "../turns";

export type ToolBlockVariant = "card" | "inline" | "rail" | "oneliner" | "terminal";
export const TOOL_BLOCK_VARIANT: ToolBlockVariant = "inline";

const DISCLOSURE_OPEN_MS = 180;
const DISCLOSURE_COLLAPSE_MS = 130;

export function disclosureShouldRender(open: boolean, present: boolean): boolean {
  return open || present;
}

export function disclosureHeightKeyframes(open: boolean, from: number, measuredHeight: number, fromOpacity = from > 0 ? 1 : 0): Keyframe[] {
  const to = open ? measuredHeight : 0;
  return [
    { height: `${Math.max(0, from)}px`, opacity: fromOpacity },
    { height: `${Math.max(0, to)}px`, opacity: open ? 1 : 0 },
  ];
}

export function disclosureSnapshotStyle(computedHeight: string, fallbackHeight: number, computedOpacity: string): { height: string; opacity: string } {
  const parsedHeight = Number.parseFloat(computedHeight);
  const height = Math.max(0, Number.isFinite(parsedHeight) ? parsedHeight : fallbackHeight);
  const parsedOpacity = Number.parseFloat(computedOpacity);
  const opacity = Number.isFinite(parsedOpacity) ? Math.min(1, Math.max(0, parsedOpacity)) : (height > 0 ? 1 : 0);
  return { height: `${height}px`, opacity: String(opacity) };
}

function pinCurrentDisclosureAnimationFrame(node: HTMLDivElement, animation: Animation | null) {
  const computed = getComputedStyle(node);
  const snapshot = disclosureSnapshotStyle(computed.height, node.getBoundingClientRect().height, computed.opacity);
  try {
    animation?.commitStyles();
  } catch {
    // Some test/browser environments do not support commitStyles for this effect.
  }
  node.style.height = snapshot.height;
  node.style.opacity = snapshot.opacity;
}

function DisclosureMotion({ open, className, children }: { open: boolean; className?: string; children: () => ReactNode }) {
  const [present, setPresent] = useState(open);
  const [animating, setAnimating] = useState(false);
  const nodeRef = useRef<HTMLDivElement>(null);
  const innerRef = useRef<HTMLDivElement>(null);
  const animationRef = useRef<Animation | null>(null);
  const mounted = useRef(false);
  const shouldRender = disclosureShouldRender(open, present);

  const requestRemeasure = () => {
    nodeRef.current?.closest(".turn-virtual-row")?.dispatchEvent(new Event("virtual-row-remeasure"));
  };

  useLayoutEffect(() => {
    const node = nodeRef.current;
    const inner = innerRef.current;
    if (!node) return;
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if (!mounted.current) {
      mounted.current = true;
      node.style.height = open ? "auto" : "0px";
      node.style.opacity = open ? "1" : "0";
      setAnimating(false);
      return;
    }

    if (open && !present) {
      setPresent(true);
      return;
    }
    if (!open && !present) {
      if (animationRef.current) pinCurrentDisclosureAnimationFrame(node, animationRef.current);
      animationRef.current?.cancel();
      animationRef.current = null;
      node.style.height = "0px";
      node.style.opacity = "0";
      setAnimating(false);
      return;
    }
    if (!inner) return;

    const computed = getComputedStyle(node);
    const currentHeight = Number.parseFloat(computed.height) || node.getBoundingClientRect().height || 0;
    const parsedOpacity = Number.parseFloat(computed.opacity);
    const currentOpacity = Number.isFinite(parsedOpacity) ? parsedOpacity : (currentHeight > 0 ? 1 : 0);
    animationRef.current?.cancel();
    animationRef.current = null;

    if (reduceMotion) {
      node.style.height = open ? "auto" : "0px";
      node.style.opacity = open ? "1" : "0";
      setAnimating(false);
      if (!open) setPresent(false);
      requestRemeasure();
      return;
    }

    const measuredHeight = inner.scrollHeight;
    const keyframes = disclosureHeightKeyframes(open, currentHeight, measuredHeight, currentOpacity);
    const animation = node.animate(keyframes, {
      duration: open ? DISCLOSURE_OPEN_MS : DISCLOSURE_COLLAPSE_MS,
      easing: open ? "cubic-bezier(.16, 1, .3, 1)" : "ease-in",
    });
    animationRef.current = animation;
    setAnimating(true);
    node.style.height = `${currentHeight}px`;
    node.style.opacity = String(currentOpacity);

    animation.onfinish = () => {
      if (animationRef.current !== animation) return;
      animationRef.current = null;
      if (open) {
        node.style.height = "auto";
        node.style.opacity = "1";
      } else {
        node.style.height = "0px";
        node.style.opacity = "0";
        setPresent(false);
      }
      setAnimating(false);
      requestRemeasure();
    };
    animation.oncancel = () => {
      if (animationRef.current === animation) {
        animationRef.current = null;
        setAnimating(false);
      }
    };
    return () => {
      if (animationRef.current === animation) {
        pinCurrentDisclosureAnimationFrame(node, animation);
        animation.cancel();
      }
    };
  }, [open, present]);

  return (
    <div
      ref={nodeRef}
      className={"disclosure-motion" + (className ? ` ${className}` : "")}
      data-open={open ? "true" : "false"}
      data-disclosure-animating={animating ? "true" : undefined}
      aria-hidden={shouldRender ? undefined : true}
    >
      <div ref={innerRef} className="disclosure-motion-inner">{shouldRender ? children() : null}</div>
    </div>
  );
}

export function ToolBlock({ b, variant = TOOL_BLOCK_VARIANT, defaultOpen = false }: { b: Extract<Block, { kind: "tool" }>; variant?: ToolBlockVariant; defaultOpen?: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  const hasOutput = Boolean(b.out);
  const mark = b.status === "running"
    ? <PinwheelSpinner size={12} />
    : <span className={"tool-dot " + (b.status === "fail" ? "fail" : "ok")} />;
  const label = variant === "oneliner"
    ? <>{mark}<span className="name">{b.name}</span>{b.detail ? <span className="detail">({b.detail})</span> : null}<span className="tool-time tabular-nums"> · 1.2s</span></>
    : variant === "terminal"
      ? <>{mark}<span className="tool-dollar">$</span><span className="name">{b.name}</span>{b.detail ? <span className="detail">{b.detail}</span> : null}</>
      : <>{mark}<span className="name">{b.name}</span><span className="detail">{b.detail}</span></>;
  return (
    <div className={`tool tool-${variant} tool-status-${b.status}`}>
      <details open>
        <summary
          aria-expanded={hasOutput ? open : undefined}
          onClick={(event) => {
            event.preventDefault();
            if (hasOutput) setOpen((value) => !value);
          }}
        >
          {variant === "oneliner" ? <Chevron /> : null}
          {label}
        </summary>
        <DisclosureMotion open={open && hasOutput}>
          {() => <div className="out selectable">{b.out}</div>}
        </DisclosureMotion>
      </details>
    </div>
  );
}

export function ActivityIndicatorBlock({ label, startedAt }: { label: "Thinking" | "Reasoning"; startedAt: number }) {
  const now = useTicker(true);
  const elapsed = Math.max(0, Math.floor((now - startedAt) / 1000));
  return (
    <div className="activity-indicator" aria-live="polite">
      <span className="activity-label">{label}</span>
      {elapsed >= 3 ? <span className="activity-elapsed tabular-nums"> · {elapsed}s</span> : null}
      <span className="activity-hint">esc to interrupt</span>
    </div>
  );
}

function durationText(stats: string): string {
  return stats.split(" · ").find((part) => /^\d+(\.\d+)?s$/.test(part.trim())) ?? "";
}

const turnActionsRowStyle: CSSProperties = {
  display: "flex",
  width: "100%",
  alignItems: "center",
  gap: 6,
};

const turnActionButtonsStyle: CSSProperties = {
  display: "inline-flex",
  alignItems: "center",
  gap: 4,
};

export function TurnActions({
  stats,
  text,
  actions,
  onFork,
  forkPending,
  copiedPreview,
}: {
  stats: string;
  text: string;
  actions: SessionActions;
  onFork: () => void;
  forkPending: boolean;
  copiedPreview?: boolean;
}) {
  const [copied, setCopied] = useState(false);
  const copiedVisible = copiedPreview ?? copied;
  const duration = durationText(stats);
  const copy = () => {
    navigator.clipboard?.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 900);
    }).catch(() => {});
  };
  return (
    <div className="turn-actions" style={turnActionsRowStyle}>
      <div style={turnActionButtonsStyle}>
        <HintTooltip label={copiedVisible ? "Copied" : "Copy response"}>
          <button className="turn-action-btn" type="button" aria-label="Copy response" onClick={copy}>
            {copiedVisible ? <Check /> : <CopyIcon />}
          </button>
        </HintTooltip>
        <Popover.Root>
          <HintTooltip label="Message actions">
            <Popover.Trigger className="turn-action-btn" aria-label="Message actions"><EllipsisIcon /></Popover.Trigger>
          </HintTooltip>
          <Popover.Portal>
            <Popover.Positioner sideOffset={6} align="start">
              <Popover.Popup className="turn-menu menu" data-agent-popup="true">
                {stats ? <div className="turn-menu-stats tabular-nums">{stats}</div> : null}
                {actions.fork ? (
                  <button className="turn-menu-item" type="button" disabled={forkPending} onClick={onFork}>
                    {forkPending ? <PinwheelSpinner size={11} /> : null}
                    <span>Fork chat</span>
                  </button>
                ) : null}
              </Popover.Popup>
            </Popover.Positioner>
          </Popover.Portal>
        </Popover.Root>
        {duration ? <span className="turn-duration tabular-nums">{duration}</span> : null}
      </div>
    </div>
  );
}

function compactCount(n: number): string {
  return n > 999 ? `${Math.round(n / 100) / 10}k` : String(n);
}

function DiffStat({ adds, dels }: { adds: number; dels: number }) {
  return (
    <span className="diff-stat tabular-nums" style={diffStatStyle}>
      <span className="adds" style={diffAddsStyle}>+{compactCount(adds)}</span>
      <span className="dels" style={diffDelsStyle}>-{compactCount(dels)}</span>
    </span>
  );
}

const monoFont = "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace";

const diffStatStyle: CSSProperties = {
  display: "inline-grid",
  gridTemplateColumns: "minmax(3ch, auto) minmax(3ch, auto)",
  columnGap: 6,
  justifyItems: "end",
  alignItems: "center",
  flexShrink: 0,
  fontFamily: monoFont,
  fontSize: 11,
  fontVariantNumeric: "tabular-nums",
  lineHeight: "16px",
};

const diffAddsStyle: CSSProperties = {
  color: "#2f9e44",
};

const diffDelsStyle: CSSProperties = {
  color: "#d64545",
};

const filesChangedContainerStyle: CSSProperties = {
  overflow: "hidden",
  border: "1px solid rgba(128, 128, 128, 0.22)",
  borderRadius: 8,
  background: "rgba(128, 128, 128, 0.04)",
};

const filesHeaderStyle: CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  gap: 8,
  padding: "7px 8px",
  borderBottom: "1px solid rgba(128, 128, 128, 0.16)",
  background: "rgba(128, 128, 128, 0.06)",
};

const filesHeaderLeftStyle: CSSProperties = {
  display: "flex",
  flex: "1 1 auto",
  minWidth: 0,
  alignItems: "center",
  gap: 6,
  fontSize: 12,
  lineHeight: "18px",
};

const filesGlyphStyle: CSSProperties = {
  display: "inline-flex",
  width: 16,
  height: 16,
  alignItems: "center",
  justifyContent: "center",
  flexShrink: 0,
  borderRadius: 4,
  background: "rgba(128, 128, 128, 0.12)",
  color: "rgba(128, 128, 128, 0.95)",
  fontFamily: monoFont,
  fontSize: 11,
  lineHeight: "16px",
};

const filesTitleStyle: CSSProperties = {
  flexShrink: 0,
  fontWeight: 600,
};

const filesSummaryTextStyle: CSSProperties = {
  minWidth: 0,
  overflow: "hidden",
  color: "rgba(128, 128, 128, 0.95)",
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
};

const filesViewDiffButtonStyle: CSSProperties = {
  flexShrink: 0,
  appearance: "none",
  border: "1px solid rgba(128, 128, 128, 0.28)",
  borderRadius: 6,
  background: "rgba(128, 128, 128, 0.08)",
  color: "inherit",
  cursor: "pointer",
  font: "inherit",
  fontSize: 11,
  lineHeight: "16px",
  padding: "2px 7px",
};

const filesTreeStyle: CSSProperties = {
  display: "grid",
  gap: 1,
  padding: 4,
};

const filesFileRowStyle: CSSProperties = {
  display: "grid",
  width: "100%",
  gridTemplateColumns: "minmax(0, 1fr) auto",
  alignItems: "center",
  gap: 8,
  appearance: "none",
  border: 0,
  borderRadius: 6,
  background: "transparent",
  color: "inherit",
  cursor: "pointer",
  font: "inherit",
  lineHeight: "18px",
  padding: "3px 5px",
  textAlign: "left",
};

const filesPathTextStyle: CSSProperties = {
  minWidth: 0,
  overflow: "hidden",
  fontFamily: monoFont,
  fontSize: 12,
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
};

const filesDirPrefixStyle: CSSProperties = {
  color: "rgba(128, 128, 128, 0.82)",
};

const filesBasenameStyle: CSSProperties = {
  color: "inherit",
  fontWeight: 600,
};

const filesDiffStyle: CSSProperties = {
  margin: "2px 0 5px",
  padding: "0 5px",
};

function changedFilesTitle(count: number): string {
  return `${count} changed ${count === 1 ? "file" : "files"}`;
}

function normalizedStatus(status: string): string {
  const value = status.trim().toLowerCase();
  switch (value) {
    case "a":
    case "add":
    case "added":
      return "added";
    case "d":
    case "delete":
    case "deleted":
      return "deleted";
    case "m":
    case "modify":
    case "modified":
      return "modified";
    case "r":
    case "rename":
    case "renamed":
      return "renamed";
    case "c":
    case "copy":
    case "copied":
      return "copied";
    case "u":
    case "unmerged":
      return "unmerged";
    default:
      return value || "changed";
  }
}

function changedFilesSummary(files: ChangedFile[]): string {
  const counts = new Map<string, number>();
  for (const file of files) {
    const status = normalizedStatus(file.status);
    counts.set(status, (counts.get(status) ?? 0) + 1);
  }
  const preferred = ["modified", "added", "deleted", "renamed", "copied", "unmerged", "changed"];
  const ordered = [
    ...preferred.filter((status) => counts.has(status)),
    ...[...counts.keys()].filter((status) => !preferred.includes(status)).sort(),
  ];
  return ordered.map((status) => `${counts.get(status)} ${status}`).join(", ");
}

function splitChangedFilePath(path: string): { dirPrefix: string; basename: string } {
  const index = path.lastIndexOf("/");
  if (index < 0) return { dirPrefix: "", basename: path };
  return {
    dirPrefix: path.slice(0, index + 1),
    basename: path.slice(index + 1) || path,
  };
}

function ChangedFilesBlock({
  files,
  revision,
  diffs,
  onDiff,
}: {
  files: ChangedFile[];
  revision?: string;
  diffs: Record<string, string>;
  onDiff: (path: string) => void;
}) {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const total = useMemo(
    () => files.reduce((sum, f) => ({ adds: sum.adds + f.adds, dels: sum.dels + f.dels }), { adds: 0, dels: 0 }),
    [files],
  );
  const statusSummary = useMemo(() => changedFilesSummary(files), [files]);
  const diffRevision = revision ?? "0";
  const diffKey = (path: string) => fileDiffCacheKey(diffRevision, path);
  const hasDiff = (path: string) => Object.prototype.hasOwnProperty.call(diffs, diffKey(path));
  const openFileDiff = (path: string) => {
    setExpanded((current) => ({ ...current, [path]: true }));
    if (!hasDiff(path)) onDiff(diffKey(path));
  };
  const firstPath = files[0]?.path;
  return (
    <div className="files-changed" style={filesChangedContainerStyle}>
      <div className="files-summary" style={filesHeaderStyle}>
        <div style={filesHeaderLeftStyle}>
          <span aria-hidden="true" style={filesGlyphStyle}>±</span>
          <span className="tabular-nums" style={filesTitleStyle}>{changedFilesTitle(files.length)}</span>
          {statusSummary ? <span className="tabular-nums" style={filesSummaryTextStyle}>{statusSummary}</span> : null}
          <DiffStat adds={total.adds} dels={total.dels} />
        </div>
        <button
          type="button"
          className="files-view-diff"
          disabled={!firstPath}
          style={{ ...filesViewDiffButtonStyle, cursor: firstPath ? "pointer" : "default", opacity: firstPath ? 1 : 0.55 }}
          onClick={() => {
            if (firstPath) openFileDiff(firstPath);
          }}
        >
          View diff
        </button>
      </div>
      <div className="files-tree" style={filesTreeStyle}>
        {files.map((file) => {
          const isOpen = Boolean(expanded[file.path]);
          const { dirPrefix, basename } = splitChangedFilePath(file.path);
          return (
            <div className="files-file" key={file.path}>
              <button
                type="button"
                className="files-file-row"
                style={filesFileRowStyle}
                onClick={() => {
                  setExpanded((m) => ({ ...m, [file.path]: !m[file.path] }));
                  if (!isOpen && !hasDiff(file.path)) onDiff(diffKey(file.path));
                }}
              >
                <span className="files-file-name" style={filesPathTextStyle}>
                  {dirPrefix ? <span style={filesDirPrefixStyle}>{dirPrefix}</span> : null}
                  <span style={filesBasenameStyle}>{basename}</span>
                </span>
                <DiffStat adds={file.adds} dels={file.dels} />
              </button>
              <DisclosureMotion open={isOpen}>
                {() => (
                  <div className="files-diff selectable" style={filesDiffStyle}>
                    {hasDiff(file.path) ? <MarkdownCodeBlock code={diffs[diffKey(file.path)]} lang="diff" /> : <div className="diff-loading">Loading diff...</div>}
                  </div>
                )}
              </DisclosureMotion>
            </div>
          );
        })}
      </div>
    </div>
  );
}

const activityRowStyle: CSSProperties = {
  display: "flex",
  width: "100%",
  alignItems: "center",
  gap: 6,
  justifyContent: "flex-start",
  appearance: "none",
  border: 0,
  borderRadius: 5,
  background: "transparent",
  boxShadow: "none",
  color: "inherit",
  font: "inherit",
  lineHeight: "18px",
  margin: 0,
  minHeight: 22,
  padding: "1px 0",
  textAlign: "left",
};

const activityButtonRowStyle: CSSProperties = {
  ...activityRowStyle,
  cursor: "pointer",
};

const activityLeafRowStyle: CSSProperties = {
  ...activityRowStyle,
  cursor: "default",
};

const activityCaretStyle: CSSProperties = {
  display: "inline-flex",
  width: 16,
  height: 16,
  alignItems: "center",
  justifyContent: "center",
  color: "rgba(128, 128, 128, 0.9)",
};

const activityRowContentStyle: CSSProperties = {
  flex: "0 1 auto",
  minWidth: 0,
  overflow: "hidden",
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
};

const activityFlatStackStyle: CSSProperties = {
  display: "grid",
  gap: 0,
  marginLeft: 0,
  paddingLeft: 0,
};

const activityDetailStyle: CSSProperties = {
  marginLeft: 0,
  paddingLeft: 0,
};

const activityMessageAlignStyle: CSSProperties = {
  marginTop: 0,
  marginBottom: 0,
};

const activityBodyAlignStyle: CSSProperties = {
  paddingTop: 0,
  paddingBottom: 0,
};

function ActivityCaret({ open, visible }: { open: boolean; visible: boolean }) {
  if (!visible) return null;
  return (
    <span aria-hidden="true" style={activityCaretStyle}>
      <svg
        className="activity-caret-icon"
        data-open={open ? "true" : "false"}
        width="12"
        height="12"
        viewBox="0 0 12 12"
        fill="none"
      >
        <path d="M4.25 2.5 7.75 6 4.25 9.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    </span>
  );
}

function activityBlockHasDetail(block: Block): boolean {
  switch (block.kind) {
    case "tool":
      return Boolean(block.out || block.detail);
    case "thinking":
      return Boolean(block.text.trim());
    case "status":
      return Boolean(block.text.trim());
    case "error":
      return Boolean(block.text.trim());
    case "files":
      return block.files.length > 0;
    default:
      return false;
  }
}

function ActivityDisclosureRow({
  label,
  open,
  canExpand,
  onToggle,
  className,
}: {
  label: string;
  open: boolean;
  canExpand: boolean;
  onToggle: () => void;
  className: string;
}) {
  const [hovered, setHovered] = useState(false);
  const [focused, setFocused] = useState(false);
  const showArrow = canExpand && (open || hovered || focused);
  const content = (
    <>
      <span className="turn-row-content" style={activityRowContentStyle}>{label}</span>
      <ActivityCaret open={open} visible={showArrow} />
    </>
  );

  if (!canExpand) {
    return (
      <div className={className} style={activityLeafRowStyle}>
        {content}
      </div>
    );
  }

  return (
    <button
      type="button"
      className={className}
      style={activityButtonRowStyle}
      aria-expanded={open}
      onBlur={() => setFocused(false)}
      onFocus={() => setFocused(true)}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onClick={onToggle}
    >
      {content}
    </button>
  );
}

function ActivityBlock({
  block,
  fileDiffs,
  onFileDiff,
  thinkingDefaultOpen,
}: {
  block: Block;
  fileDiffs: Record<string, string>;
  onFileDiff: (path: string) => void;
  thinkingDefaultOpen: boolean;
}) {
  switch (block.kind) {
    case "tool":
      return <ToolBlock b={block} defaultOpen />;
    case "assistant":
      return <div className="turn-activity-assistant selectable"><ChatMarkdown text={block.text} streaming={block.open} /></div>;
    case "thinking":
      return <div className="turn-thinking-detail">{block.text}</div>;
    case "status":
      return <div className="status-line">{block.text}</div>;
    case "error":
      return <div className="error-block-wrap"><div className="error-block">{block.text}</div></div>;
    case "files":
      return <ChangedFilesBlock files={block.files} revision={block.revision} diffs={fileDiffs} onDiff={onFileDiff} />;
    default:
      return null;
  }
}

function TurnActivity({
  group,
  expanded,
  setExpanded,
  expandedItems,
  setExpandedItems,
  fileDiffs,
  onFileDiff,
  thinkingDefaultOpen,
}: {
  group: TurnGroup;
  expanded: boolean;
  setExpanded: (v: boolean) => void;
  expandedItems: Record<string, boolean>;
  setExpandedItems: (next: Record<string, boolean>) => void;
  fileDiffs: Record<string, string>;
  onFileDiff: (path: string) => void;
  thinkingDefaultOpen: boolean;
}) {
  if (!group.activity.length) return null;
  const summary = summarizeTurnActivity(group.activity);
  return (
    <div className="msg assistant" style={activityMessageAlignStyle}>
      <div className="body selectable" style={activityBodyAlignStyle}>
        <div className="turn-activity" style={activityFlatStackStyle}>
          <ActivityDisclosureRow
            label={summary}
            open={expanded}
            canExpand
            className={"turn-summary" + (expanded ? " open" : "")}
            onToggle={() => setExpanded(!expanded)}
          />
          <DisclosureMotion open={expanded}>
            {() => (
              <div className="turn-activity-list" style={activityFlatStackStyle}>
                {group.activity.map((block, i) => {
                  if (block.kind === "assistant") {
                    return (
                      <div className="turn-activity-item" key={`${group.id}:${i}`}>
                        <ActivityBlock block={block} fileDiffs={fileDiffs} onFileDiff={onFileDiff} thinkingDefaultOpen={thinkingDefaultOpen} />
                      </div>
                    );
                  }
                  const key = `${group.id}:${i}`;
                  const open = Boolean(expandedItems[key]);
                  const canExpand = activityBlockHasDetail(block);
                  return (
                    <div className="turn-activity-item" key={key}>
                      <ActivityDisclosureRow
                        label={activityRowLabel(block)}
                        open={open}
                        canExpand={canExpand}
                        className={"turn-activity-row" + (open ? " open" : "")}
                        onToggle={() => setExpandedItems({ ...expandedItems, [key]: !open })}
                      />
                      <DisclosureMotion open={open && canExpand}>
                        {() => (
                          <div className="turn-activity-detail" style={activityDetailStyle}>
                            <ActivityBlock block={block} fileDiffs={fileDiffs} onFileDiff={onFileDiff} thinkingDefaultOpen={thinkingDefaultOpen} />
                          </div>
                        )}
                      </DisclosureMotion>
                    </div>
                  );
                })}
              </div>
            )}
          </DisclosureMotion>
        </div>
      </div>
    </div>
  );
}

function TurnGroupView({
  group,
  status,
  actions,
  onFork,
  forkPending,
  fileDiffs,
  onFileDiff,
  thinkingDefaultOpen,
  expandedTurns,
  setExpandedTurns,
  expandedItems,
  setExpandedItems,
}: {
  group: TurnGroup;
  status?: string;
  actions: SessionActions;
  onFork: () => void;
  forkPending: boolean;
  fileDiffs: Record<string, string>;
  onFileDiff: (path: string) => void;
  thinkingDefaultOpen: boolean;
  expandedTurns: Record<string, boolean>;
  setExpandedTurns: (next: Record<string, boolean>) => void;
  expandedItems: Record<string, boolean>;
  setExpandedItems: (next: Record<string, boolean>) => void;
}) {
  const live = status === "running" && !group.done;
  return (
    <div className="turn-group">
      {group.user ? <div className="msg user"><div className="body selectable">{group.user.text}</div></div> : null}
      {live
        ? group.activity.map((block, i) => (
          <ActivityBlock key={i} block={block} fileDiffs={fileDiffs} onFileDiff={onFileDiff} thinkingDefaultOpen={thinkingDefaultOpen} />
        ))
        : (
          <TurnActivity
            group={group}
            expanded={Boolean(expandedTurns[group.id])}
            setExpanded={(open) => setExpandedTurns({ ...expandedTurns, [group.id]: open })}
            expandedItems={expandedItems}
            setExpandedItems={setExpandedItems}
            fileDiffs={fileDiffs}
            onFileDiff={onFileDiff}
            thinkingDefaultOpen={thinkingDefaultOpen}
          />
        )}
      {group.assistant ? <div className="msg assistant"><div className="body selectable"><ChatMarkdown text={group.assistant.text} streaming={group.assistant.open} /></div></div> : null}
      {group.footer ? <TurnActions stats={group.footer.text} text={group.assistant?.text ?? ""} actions={actions} onFork={onFork} forkPending={forkPending} /> : null}
    </div>
  );
}

export function Blocks({
  blocks,
  status,
  actions,
  onFork,
  forkPending,
  fileDiffs = {},
  onFileDiff = () => {},
  thinkingDefaultOpen = false,
  initialExpandedTurns = {},
  initialExpandedItems = {},
}: {
  blocks: Block[];
  status?: string;
  actions: SessionActions;
  onFork: () => void;
  forkPending: boolean;
  fileDiffs?: Record<string, string>;
  onFileDiff?: (path: string) => void;
  thinkingDefaultOpen?: boolean;
  initialExpandedTurns?: Record<string, boolean>;
  initialExpandedItems?: Record<string, boolean>;
}) {
  const activity = activityIndicatorState(status, blocks);
  const activityKey = `${status}:${activity.label}:${activityTailKey(blocks)}`;
  const activityStartedAt = useActivityStartedAt(activity.show, activityKey);
  const groups = useMemo(() => groupTurns(blocks, status), [blocks, status]);
  const virtualized = groups.length > 24;
  const virtual = useVirtualTurns(groups.length, virtualized);
  const [expandedTurns, setExpandedTurns] = useState<Record<string, boolean>>(() => initialExpandedTurns);
  const [expandedItems, setExpandedItems] = useState<Record<string, boolean>>(() => initialExpandedItems);
  const start = virtualized ? virtual.range.start : 0;
  const end = virtualized ? virtual.range.end : groups.length - 1;
  const visible = groups.slice(start, end + 1);
  return (
    <div className="turn-list" ref={virtual.rootRef} data-virtualized={virtualized ? "true" : undefined}>
      {virtualized ? <div style={{ height: virtual.range.top }} /> : null}
      {visible.map((group, offset) => {
        const index = start + offset;
        return (
          <div className="turn-virtual-row" key={group.id} ref={virtual.measure(index)}>
            <TurnGroupView
              group={group}
              status={status}
              actions={actions}
              onFork={onFork}
              forkPending={forkPending}
              fileDiffs={fileDiffs}
              onFileDiff={onFileDiff}
              thinkingDefaultOpen={thinkingDefaultOpen}
              expandedTurns={expandedTurns}
              setExpandedTurns={setExpandedTurns}
              expandedItems={expandedItems}
              setExpandedItems={setExpandedItems}
            />
          </div>
        );
      })}
      {virtualized ? <div style={{ height: virtual.range.bottom }} /> : null}
      {activity.show ? <ActivityIndicatorBlock key={activityKey} label={activity.label} startedAt={activityStartedAt} /> : null}
    </div>
  );
}
