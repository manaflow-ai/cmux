import { useCallback, useEffect, useLayoutEffect, useMemo, useState, type RefObject } from "react";
import type { CommandEntry, CommandGroup, CtrlJMode } from "../session";
import { menuActionForKey } from "../keymap";
import { CmdkMenu } from "./CmdkMenu";

function commandContext(text: string, caret: number, groups: CommandGroup[]) {
  const byTrigger = new Map(groups.map((g) => [g.trigger, g.commands]));
  const slash = byTrigger.get("/");
  if (slash && text.startsWith("/") && caret >= 1 && !/\s/.test(text.slice(1, caret))) {
    return { trigger: "/" as const, start: 0, query: text.slice(1, caret), commands: slash };
  }
  for (let i = caret - 1; i >= 0; i--) {
    if (/\s/.test(text[i])) break;
    const trigger = text[i] as CommandGroup["trigger"];
    const commands = byTrigger.get(trigger);
    if (commands && trigger !== "/" && (i === 0 || /\s/.test(text[i - 1]))) {
      const q = text.slice(i + 1, caret);
      if (!/\s/.test(q)) return { trigger, start: i, query: q, commands };
      return null;
    }
  }
  return null;
}

function fuzzyScore(name: string, query: string): number {
  const n = name.toLowerCase();
  const q = query.toLowerCase();
  if (!q) return 0;
  const direct = n.indexOf(q);
  if (direct >= 0) return direct;
  let pos = -1;
  let score = 0;
  for (const ch of q) {
    const next = n.indexOf(ch, pos + 1);
    if (next < 0) return Number.POSITIVE_INFINITY;
    score += next - pos;
    pos = next;
  }
  return score + n.length / 1000;
}

export function isCtrlJ(e: React.KeyboardEvent<HTMLTextAreaElement>): boolean {
  return e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "j";
}

export function insertNewlineAtCaret(text: string, setText: (v: string) => void, ref: RefObject<HTMLTextAreaElement | null>) {
  const el = ref.current;
  const start = el?.selectionStart ?? text.length;
  const end = el?.selectionEnd ?? start;
  const next = text.slice(0, start) + "\n" + text.slice(end);
  setText(next);
  requestAnimationFrame(() => {
    const pos = start + 1;
    ref.current?.focus();
    ref.current?.setSelectionRange(pos, pos);
  });
}

export function useCommandMenu(
  text: string,
  setText: (v: string) => void,
  groups: CommandGroup[],
  ref: RefObject<HTMLTextAreaElement | null>,
  _ctrlJ: CtrlJMode,
) {
  const [selected, setSelected] = useState(0);
  const [caret, setCaret] = useState(text.length);
  const syncCaret = useCallback(() => {
    setCaret(ref.current?.selectionStart ?? text.length);
  }, [ref, text.length]);
  useLayoutEffect(() => {
    setCaret(ref.current?.selectionStart ?? text.length);
  }, [ref, text]);
  const ctx = commandContext(text, caret, groups);
  const ctxKey = ctx ? `${ctx.trigger}:${ctx.start}:${ctx.query}` : "";
  const [dismissedKey, setDismissedKey] = useState("");
  const items = useMemo(() => {
    if (!ctx) return [];
    return ctx.commands
      .map((c) => ({ command: c, score: fuzzyScore(c.name, ctx.query) }))
      .filter((c) => Number.isFinite(c.score))
      .sort((a, b) => a.score - b.score || a.command.name.localeCompare(b.command.name))
      .map((c) => c.command)
      .slice(0, 12);
  }, [ctx?.trigger, ctx?.query, ctx?.commands]);
  const open = Boolean(ctx && dismissedKey !== ctxKey);
  useEffect(() => {
    setSelected(0);
  }, [ctxKey]);
  useEffect(() => {
    if (selected >= items.length) setSelected(0);
  }, [items.length, selected]);
  const close = useCallback(() => {
    setSelected(0);
    setDismissedKey(ctxKey);
  }, [ctxKey]);
  const insert = useCallback((cmd: CommandEntry) => {
    if (!ctx) return;
    const caret = ref.current?.selectionStart ?? text.length;
    const before = text.slice(0, ctx.start);
    const after = text.slice(caret);
    const next = `${before}${ctx.trigger}${cmd.name} ${after}`;
    setDismissedKey("");
    setText(next);
    requestAnimationFrame(() => {
      const pos = before.length + ctx.trigger.length + cmd.name.length + 1;
      ref.current?.focus();
      ref.current?.setSelectionRange(pos, pos);
    });
  }, [ctx, ref, setText, text]);
  const onKeyDown = useCallback((e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (!open) return false;
    const action = menuActionForKey(e.nativeEvent);
    if (action === "menu-next") {
      e.preventDefault();
      e.stopPropagation();
      if (items.length) setSelected((i) => (i + 1) % items.length);
      return true;
    }
    if (action === "menu-prev") {
      e.preventDefault();
      e.stopPropagation();
      if (items.length) setSelected((i) => (i + items.length - 1) % items.length);
      return true;
    }
    if (action === "menu-accept") {
      e.preventDefault();
      e.stopPropagation();
      if (items.length) insert(items[selected] ?? items[0]);
      setSelected(0);
      return true;
    }
    if (action === "menu-close") {
      e.preventDefault();
      e.stopPropagation();
      close();
      return true;
    }
    return false;
  }, [close, insert, items, open, selected]);
  const menu = open ? (
    <div className="command-menu" data-agent-popup="true">
      <CmdkMenu
        inline
        className="mention-menu"
        groups={[{
          id: ctx!.trigger,
          items: items.map((cmd) => ({
            id: cmd.name,
            label: `${ctx!.trigger}${cmd.name}`,
            description: cmd.description,
            onSelect: () => insert(cmd),
            value: `${cmd.name} ${cmd.description ?? ""}`,
          })),
        }]}
      />
    </div>
  ) : null;
  return { open, close, onKeyDown, onSelect: syncCaret, menu };
}
