import { Popover } from "@base-ui-components/react/popover";
import { useCallback, useLayoutEffect, useMemo, useRef, useState, type Dispatch, type ReactNode, type RefObject, type SetStateAction } from "react";
import { menuActionForKey } from "../keymap";
import type { OptionValue, Provider, SessionOption } from "../session";
import { BarsIcon, BoltIcon, Check, Chevron, EllipsisIcon, FolderIcon, PlanIcon, ProviderIcon, SearchIcon, ShieldIcon, SparkIcon, basename } from "./icons";
import { CmdkMenu, type CmdkGroup } from "./CmdkMenu";
import { HintTooltip } from "./Tooltips";
import { currentChoice, cycleSelect, effortFill, isOffLikeValue, optionAction, optionTooltip, prettyValue, visibleChoices } from "./options";

function CwdPopover({ cwd, onChange, onCommit }: { cwd: string; onChange: (v: string) => void; onCommit: (v: string) => void }) {
  return (
    <Popover.Root onOpenChange={(open) => { if (!open) onCommit(cwd); }}>
      <HintTooltip label="Change working directory">
        <Popover.Trigger className="row-control cwd-trigger">
          <FolderIcon />
          <span className="cwd-label">{basename(cwd)}</span>
        </Popover.Trigger>
      </HintTooltip>
      <Popover.Portal>
        <Popover.Positioner sideOffset={8} align="start">
          <Popover.Popup className="popover" data-agent-popup="true">
            <div className="popover-label">Working directory</div>
            <input
              className="cwd-edit"
              spellCheck={false}
              value={cwd}
              autoFocus
              onChange={(e) => onChange(e.target.value)}
              onBlur={(e) => onCommit(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  onCommit((e.target as HTMLInputElement).value);
                  (e.target as HTMLInputElement).blur();
                }
              }}
            />
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function InlineSelect({
  option,
  icon,
  choiceIcon,
  label,
  onChange,
  open,
  onOpenChange,
}: {
  option: SessionOption;
  icon: ReactNode;
  choiceIcon?: (value: string) => ReactNode;
  label: string;
  onChange: (id: string, value: OptionValue) => void;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const value = String(option.value ?? "");
  const visible = visibleChoices(option);
  const choices = visible.length ? visible : (value ? [{ value, label: value }] : []);
  const current = choices.find((c) => c.value === value)?.label ?? (value || option.label);
  const trigger = (
    <button type="button" className="row-control row-select select-trigger" aria-label={option.label} disabled={option.disabled || !choices.length}>
      <span className="row-icon">{icon}</span>
      <span className="row-value">{label || current}</span>
    </button>
  );
  return (
    <HintTooltip label={optionTooltip(option)} action={optionAction(option.id)}>
      <span>
        <CmdkMenu
          open={open}
          onOpenChange={onOpenChange}
          trigger={trigger}
          className="option-menu"
          groups={[{
            id: option.id,
            items: choices.map((c) => ({
              id: c.value,
              label: c.label,
              description: c.description,
              icon: choiceIcon?.(c.value),
              selected: c.value === option.value,
              onSelect: () => onChange(option.id, String(c.value)),
            })),
          }]}
        />
      </span>
    </HintTooltip>
  );
}

const INLINE_OPTION_IDS = new Set(["model", "context", "fastMode", "mode", "permissionMode"]);

function isInlineOption(option: SessionOption): boolean {
  return INLINE_OPTION_IDS.has(option.id) || option.role === "effort" || option.role === "approval";
}

export function OverflowMenu({ options, onChange }: { options: SessionOption[]; onChange: (id: string, value: OptionValue) => void }) {
  if (!options.length) return null;
  const groups: CmdkGroup[] = options.map((option) => ({
    id: option.id,
    label: option.label,
    items: option.kind === "toggle"
      ? [{
          id: `${option.id}:toggle`,
          label: option.label,
          description: option.value ? "Currently on" : "Currently off",
          selected: Boolean(option.value),
          disabled: option.disabled,
          onSelect: () => onChange(option.id, !option.value),
        }]
      : (option.choices ?? []).map((choice) => ({
          id: `${option.id}:${choice.value}`,
          label: choice.label,
          description: choice.description,
          selected: choice.value === option.value,
          disabled: option.disabled || choice.disabled,
          onSelect: () => onChange(option.id, choice.value),
        })),
  }));
  return (
    <Popover.Root>
      <HintTooltip label="More options">
        <Popover.Trigger className="row-control row-icon-only" aria-label="More options">
          <EllipsisIcon />
        </Popover.Trigger>
      </HintTooltip>
      <Popover.Portal>
        <Popover.Positioner sideOffset={8} align="end">
          <Popover.Popup className="overflow-menu menu">
            <CmdkMenu groups={groups} inline />
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function StaticProvider({ provider, running = false }: { provider: Provider; running?: boolean }) {
  return (
    <HintTooltip label="Provider">
      <span className={"row-control static-provider" + (running ? " provider-running" : "")}>
        <ProviderIcon provider={provider} />
        <span className="row-value">{provider.label}</span>
      </span>
    </HintTooltip>
  );
}

function StaticCwd({ cwd }: { cwd: string }) {
  return (
    <HintTooltip label="Working directory">
      <span className="row-control cwd-trigger">
        <FolderIcon />
        <span className="cwd-label">{basename(cwd)}</span>
      </span>
    </HintTooltip>
  );
}

function modelOption(options: SessionOption[]): SessionOption | undefined {
  return options.find((o) => o.id === "model" && o.kind === "select");
}

function useAutofocus(open: boolean, ref: RefObject<HTMLElement | null>) {
  useLayoutEffect(() => {
    if (!open) return;
    ref.current?.focus();
    requestAnimationFrame(() => ref.current?.focus());
  }, [open, ref]);
}

function usePickerTypeToSearch(open: boolean, ref: RefObject<HTMLInputElement | null>, setQuery: Dispatch<SetStateAction<string>>) {
  useLayoutEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.isComposing || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey || e.key.length !== 1) return;
      if (e.target === ref.current) return;
      e.preventDefault();
      ref.current?.focus();
      setQuery((q) => q + e.key);
    };
    window.addEventListener("keydown", onKeyDown, true);
    return () => window.removeEventListener("keydown", onKeyDown, true);
  }, [open, ref, setQuery]);
}

function useBoundedActiveIndex(open: boolean, key: string, count: number) {
  const [active, setActive] = useState(0);
  useLayoutEffect(() => {
    setActive(0);
  }, [key]);
  useLayoutEffect(() => {
    if (!open) return;
    setActive((i) => Math.min(Math.max(i, 0), Math.max(0, count - 1)));
  }, [count, open]);
  return [active, setActive] as const;
}

interface PickerModelItem {
  id: string;
  provider: Provider;
  value: string;
  label: string;
  description?: string;
  disabled?: boolean;
  disabledReason?: string;
  selected: boolean;
  search: string;
}

function providerModelItems(p: Provider, currentProvider: string, options: SessionOption[]): PickerModelItem[] {
  const model = modelOption(options);
  const choices = model?.choices?.length ? model.choices : [];
  if (!choices.length) {
    return [{
      id: `${p.id}:default`,
      provider: p,
      value: "",
      label: "Default",
      description: "Model loads at start",
      selected: p.id === currentProvider && !model?.value,
      search: `${p.label} default`,
    }];
  }
  return choices.map((choice) => ({
    id: `${p.id}:${choice.value}`,
    provider: p,
    value: choice.value,
    label: choice.label,
    description: choice.description,
    disabled: choice.disabled,
    disabledReason: choice.disabledReason,
    selected: p.id === currentProvider && choice.value === model?.value,
    search: `${p.label} ${choice.label} ${choice.value} ${choice.description ?? ""}`,
  }));
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

export function HarnessModelPicker({
  provider,
  providers,
  options,
  allProviderOptions,
  open,
  onOpenChange,
  onSelect,
  running = false,
  initialQuery = "",
}: {
  provider: string;
  providers: Provider[];
  options: SessionOption[];
  allProviderOptions: Record<string, SessionOption[]>;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (provider: string, model: string) => void;
  running?: boolean;
  initialQuery?: string;
}) {
  const installed = providers.filter((p) => p.installed !== false);
  const missing = providers.filter((p) => p.installed === false);
  const currentProvider = providers.find((p) => p.id === provider) ?? { id: provider, label: provider };
  const currentModel = modelOption(options);
  const label = currentChoice(currentModel)?.label ?? String(currentModel?.value || currentProvider.label);
  const [railProvider, setRailProvider] = useState(provider);
  const [query, setQuery] = useState(initialQuery);
  const searchRef = useRef<HTMLInputElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const railRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  useAutofocus(open, searchRef);
  usePickerTypeToSearch(open, searchRef, setQuery);
  const activeProvider = installed.find((p) => p.id === railProvider) ?? installed.find((p) => p.id === provider) ?? installed[0];
  const providerItems = useMemo(() => new Map(installed.map((p) => {
    const opts = p.id === provider ? options : (allProviderOptions[p.id] ?? []);
    return [p.id, providerModelItems(p, provider, opts)];
  })), [allProviderOptions, installed, options, provider]);
  const q = query.trim();
  const listItems = useMemo(() => {
    if (q) {
      return Array.from(providerItems.values()).flat()
        .map((item) => ({ item, score: fuzzyScore(item.search, q) }))
        .filter((x) => Number.isFinite(x.score))
        .sort((a, b) => a.score - b.score || a.item.label.localeCompare(b.item.label))
        .map((x) => x.item);
    }
    return activeProvider ? providerItems.get(activeProvider.id) ?? [] : [];
  }, [activeProvider, providerItems, q]);
  const [activeIndex, setActiveIndex] = useBoundedActiveIndex(open, `${q}:${activeProvider?.id ?? ""}:${listItems.map((i) => i.id).join("|")}`, listItems.length);
  useLayoutEffect(() => {
    if (!open) return;
    const id = listItems[activeIndex]?.id;
    if (!id) return;
    listRef.current?.querySelector<HTMLElement>(`#${CSS.escape(id)}`)?.scrollIntoView({ block: "nearest" });
  }, [activeIndex, listItems, open]);
  const choose = useCallback((item: PickerModelItem) => {
    if (item.disabled) return;
    if (item.provider.id === provider && item.value === "") {
      onOpenChange(false);
      return;
    }
    onSelect(item.provider.id, item.value);
    onOpenChange(false);
  }, [onOpenChange, onSelect, provider]);
  const keyNav = useCallback((e: React.KeyboardEvent) => {
    const action = menuActionForKey(e.nativeEvent);
    const inRail = e.target instanceof HTMLElement && Boolean(e.target.closest(".model-picker-rail"));
    const plainArrow = !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey;
    if (e.key === "Tab" && !q && activeProvider) {
      e.preventDefault();
      if (inRail) searchRef.current?.focus();
      else (railRef.current?.querySelector("[aria-selected='true']") as HTMLElement | null)?.focus();
    } else if (inRail && plainArrow && (e.key === "ArrowRight" || e.key === "ArrowDown")) {
      e.preventDefault();
      const i = Math.max(0, installed.findIndex((p) => p.id === activeProvider?.id));
      const nextProvider = installed[(i + 1) % installed.length];
      if (nextProvider) setRailProvider(nextProvider.id);
    } else if (inRail && plainArrow && (e.key === "ArrowLeft" || e.key === "ArrowUp")) {
      e.preventDefault();
      const i = Math.max(0, installed.findIndex((p) => p.id === activeProvider?.id));
      const nextProvider = installed[(i + installed.length - 1) % installed.length];
      if (nextProvider) setRailProvider(nextProvider.id);
    } else if (action === "menu-next") {
      e.preventDefault();
      setActiveIndex((i) => listItems.length ? (i + 1) % listItems.length : 0);
    } else if (action === "menu-prev") {
      e.preventDefault();
      setActiveIndex((i) => listItems.length ? (i + listItems.length - 1) % listItems.length : 0);
    } else if (action === "menu-accept") {
      e.preventDefault();
      const item = listItems[activeIndex];
      if (item) choose(item);
    } else if (action === "menu-close") {
      e.preventDefault();
      onOpenChange(false);
    }
  }, [activeIndex, activeProvider, choose, installed, listItems, onOpenChange, q, setActiveIndex]);
  const trigger = (
    <button ref={triggerRef} type="button" className={"row-control provider-model-trigger select-trigger" + (running ? " provider-running" : "")} aria-label="Switch harness or model">
      <ProviderIcon provider={currentProvider} />
      <span className="row-value">{label}</span>
      <span className="chev"><Chevron /></span>
    </button>
  );
  return (
    <HintTooltip label="Switch harness or model" action="open-model">
      <span>
        <Popover.Root
          open={open}
          onOpenChange={(next) => {
            if (next) {
              setRailProvider(provider);
              setQuery(initialQuery);
            }
            onOpenChange(next);
          }}
        >
          <Popover.Trigger render={trigger} />
          <Popover.Portal>
            <Popover.Positioner className="select-positioner" sideOffset={8} align="start">
              <Popover.Popup
                className="model-picker-menu"
                data-agent-popup="true"
                role="dialog"
                aria-label="Switch harness or model"
                initialFocus={searchRef}
                finalFocus={triggerRef}
                onKeyDown={keyNav}
              >
                <div className="model-picker-shell">
                  {!q ? (
                    <div className="model-picker-rail" role="tablist" aria-label="Harnesses" ref={railRef}>
                      <div className="model-picker-rail-top">
                        {installed.map((p) => (
                          <HintTooltip key={p.id} label={p.label}>
                            <button
                              type="button"
                              role="tab"
                              className={"rail-btn" + (p.id === activeProvider?.id ? " active" : "")}
                              aria-label={p.label}
                              aria-selected={p.id === activeProvider?.id}
                              onClick={() => setRailProvider(p.id)}
                            >
                              <ProviderIcon provider={p} />
                            </button>
                          </HintTooltip>
                        ))}
                      </div>
                      {missing.length ? (
                        <div className="model-picker-rail-bottom">
                          {missing.map((p) => (
                            <HintTooltip key={p.id} label={p.installCommand ? `Copy install command for ${p.label}` : `${p.label} not installed`}>
                              <button
                                type="button"
                                className="rail-btn missing"
                                aria-label={`${p.label} not installed`}
                                onClick={() => {
                                  if (p.installCommand) navigator.clipboard?.writeText(p.installCommand).catch(() => {});
                                }}
                              >
                                <ProviderIcon provider={p} />
                              </button>
                            </HintTooltip>
                          ))}
                        </div>
                      ) : null}
                    </div>
                  ) : null}
                  <div className="model-picker-main">
                    <div className="model-picker-search">
                      <SearchIcon />
                      <input
                        ref={searchRef}
                        role="combobox"
                        aria-label="Search models"
                        aria-expanded="true"
                        aria-controls="model-picker-list"
                        aria-activedescendant={listItems[activeIndex]?.id}
                        value={query}
                        onChange={(e) => setQuery(e.target.value)}
                        placeholder="Search models..."
                        spellCheck={false}
                      />
                    </div>
                    <div className="model-picker-list" id="model-picker-list" role="listbox" aria-label="Models" ref={listRef}>
                      {listItems.length ? listItems.map((item, i) => {
                        const row = (
                          <button
                            key={item.id}
                            id={item.id}
                            type="button"
                            role="option"
                            className={"model-row" + (i === activeIndex ? " active" : "") + (item.disabled ? " disabled" : "")}
                            disabled={item.disabled}
                            aria-selected={item.selected}
                            aria-disabled={item.disabled ? "true" : undefined}
                            onMouseEnter={() => setActiveIndex(i)}
                            onClick={() => choose(item)}
                          >
                            <ProviderIcon provider={item.provider} />
                            <span className="model-row-main">
                              <span className="model-row-name">{item.label}</span>
                              <span className="model-row-subtitle">
                                {item.disabled ? item.disabledReason ?? "Unavailable" : item.description ?? item.provider.label}
                              </span>
                            </span>
                            {item.selected ? <span className="mi-check selected"><Check /></span> : null}
                          </button>
                        );
                        return item.disabled && item.disabledReason
                          ? <HintTooltip key={item.id} label={item.disabledReason}><span className="model-row-tooltip-wrap">{row}</span></HintTooltip>
                          : row;
                      }) : (
                        <div className="model-picker-empty">No models found</div>
                      )}
                    </div>
                  </div>
                </div>
              </Popover.Popup>
            </Popover.Positioner>
          </Popover.Portal>
        </Popover.Root>
      </span>
    </HintTooltip>
  );
}

export function StatusRow({
  provider,
  providers,
  allProviderOptions,
  onProviderModelChange,
  cwd,
  onCwdChange,
  onCwdCommit,
  options,
  onChange,
  openOptionId,
  setOpenOptionId,
  trailing,
  running = false,
}: {
  provider: string;
  providers?: Provider[];
  allProviderOptions?: Record<string, SessionOption[]>;
  onProviderModelChange?: (provider: string, model: string) => void;
  cwd: string;
  onCwdChange?: (v: string) => void;
  onCwdCommit?: (v: string) => void;
  options: SessionOption[];
  onChange: (id: string, value: OptionValue) => void;
  openOptionId: string | null;
  setOpenOptionId: (id: string | null) => void;
  trailing?: ReactNode;
  running?: boolean;
}) {
  const effortLike = options.filter((o) => o.role === "effort" && o.kind === "select" && !isOffLikeValue(String(o.value)));
  const context = options.find((o) => o.id === "context" && o.kind === "select");
  const fast = options.find((o) => o.id === "fastMode" && o.kind === "toggle");
  const approval = options.find((o) => o.role === "approval" && o.kind === "toggle");
  const mode = options.find((o) => (o.id === "mode" || o.id === "permissionMode") && o.kind === "select");
  const overflow = options.filter((o) => !isInlineOption(o));
  const modeLabel = mode && !["", "default", "build"].includes(String(mode.value)) ? prettyValue(mode) : "";
  const providerInfo = providers?.find((p) => p.id === provider) ?? { id: provider, label: provider };
  return (
    <div className="status-row">
      {providers && onProviderModelChange
        ? (
          <HarnessModelPicker
            provider={provider}
            providers={providers}
            options={options}
            allProviderOptions={allProviderOptions ?? {}}
            open={openOptionId === "modelPicker"}
            onOpenChange={(open) => setOpenOptionId(open ? "modelPicker" : null)}
            onSelect={onProviderModelChange}
            running={running}
          />
        )
        : <StaticProvider provider={providerInfo} running={running} />}
      {fast ? (
        <HintTooltip label={optionTooltip(fast)} action="toggle-fast">
          <button
            type="button"
            aria-label={fast.label}
            disabled={fast.disabled}
            className={"row-control row-icon-only fast-toggle" + (fast.value ? " active" : "")}
            onClick={() => onChange(fast.id, !fast.value)}
          >
            <BoltIcon />
          </button>
        </HintTooltip>
      ) : null}
      {effortLike.map((option) => (
        <InlineSelect
          key={option.id}
          option={option}
          icon={<BarsIcon filled={effortFill(option)} />}
          choiceIcon={(value) => <BarsIcon filled={effortFill(option, value)} />}
          label={prettyValue(option)}
          onChange={onChange}
          open={openOptionId === option.id}
          onOpenChange={(open) => setOpenOptionId(open ? option.id : null)}
        />
      ))}
      {context ? (
        <InlineSelect
          option={context}
          icon={<SparkIcon />}
          label={prettyValue(context)}
          onChange={onChange}
          open={openOptionId === context.id}
          onOpenChange={(open) => setOpenOptionId(open ? context.id : null)}
        />
      ) : null}
      {mode && modeLabel ? (
        <HintTooltip label={optionTooltip(mode)} action="cycle-mode">
          <button type="button" className="row-control" onClick={() => cycleSelect(mode, onChange)}>
            <PlanIcon />
            <span className="row-value">{modeLabel}</span>
          </button>
        </HintTooltip>
      ) : null}
      {onCwdChange && onCwdCommit ? <CwdPopover cwd={cwd} onChange={onCwdChange} onCommit={onCwdCommit} /> : <StaticCwd cwd={cwd} />}
      {approval ? (
        <HintTooltip label={optionTooltip(approval)}>
          <button
            type="button"
            aria-label={approval.label}
            disabled={approval.disabled}
            className={"row-control row-icon-only shield-toggle" + (approval.value ? " active" : "")}
            onClick={() => onChange(approval.id, !approval.value)}
          >
            <ShieldIcon />
          </button>
        </HintTooltip>
      ) : null}
      <OverflowMenu options={overflow} onChange={onChange} />
      <div className="status-row-spacer" />
      {trailing}
    </div>
  );
}
