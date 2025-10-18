import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { Skeleton } from "@heroui/react";
import * as Popover from "@radix-ui/react-popover";
import { useVirtualizer } from "@tanstack/react-virtual";
import { clsx } from "clsx";
import fuzzysort from "fuzzysort";
import {
  AlertTriangle,
  Check,
  ChevronDown,
  Loader2,
  OctagonAlert,
} from "lucide-react";
import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type ComponentType,
  type ReactNode,
} from "react";

interface OptionWarning {
  tooltip: ReactNode;
  onClick?: () => void;
}

export interface SelectOptionObject {
  label: string;
  value: string;
  isUnavailable?: boolean;
  displayLabel?: string;
  // Optional icon element to render before the label
  icon?: ReactNode;
  // Stable key for the icon, used for de-duplication in stacked view
  iconKey?: string;
  // Render as a non-selectable heading row
  heading?: boolean;
  warning?: OptionWarning;
}

export type SelectOption = string | SelectOptionObject;

export type SearchableSelectHandle = {
  open: (options?: { focusValue?: string }) => void;
  close: () => void;
};

export interface SearchableSelectProps {
  options: SelectOption[];
  value: string[];
  onChange: (value: string[]) => void;
  placeholder?: string;
  singleSelect?: boolean;
  className?: string;
  classNames?: {
    root?: string;
    trigger?: string;
    popover?: string;
    command?: string;
    commandInput?: string;
    commandList?: string;
    commandEmpty?: string;
    commandGroup?: string;
    commandItem?: string;
    footer?: string;
  };
  loading?: boolean;
  maxTagCount?: number;
  showSearch?: boolean;
  disabled?: boolean;
  // Label shown in multi-select trigger as "N <countLabel>"
  countLabel?: string;
  // Optional icon rendered at the start of the trigger (outside option labels)
  leftIcon?: ReactNode;
  // Optional footer rendered below the scroll container
  footer?: ReactNode;
  itemVariant?: "default" | "agent";
  optionItemComponent?: ComponentType<OptionItemRenderProps>;
  maxCountPerValue?: number;
}

interface WarningIndicatorProps {
  warning: OptionWarning;
  onActivate?: () => void;
  className?: string;
}

export function WarningIndicator({
  warning,
  onActivate,
  className,
}: WarningIndicatorProps) {
  return (
    <Tooltip delayDuration={0}>
      <TooltipTrigger asChild>
        <button
          type="button"
          onClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            warning.onClick?.();
            onActivate?.();
          }}
          aria-label="Open settings to finish setup"
          className={clsx(
            "inline-flex h-5 w-5 items-center justify-center rounded-sm",
            "cursor-pointer text-red-500 hover:text-red-600",
            "dark:text-red-400 dark:hover:text-red-300",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500/60",
            "focus-visible:ring-offset-1 focus-visible:ring-offset-white dark:focus-visible:ring-offset-neutral-900",
            className
          )}
        >
          <OctagonAlert className="h-3.5 w-3.5" aria-hidden="true" />
          <span className="sr-only">Setup required</span>
        </button>
      </TooltipTrigger>
      <TooltipContent className="max-w-xs text-xs leading-snug">
        {warning.tooltip}
      </TooltipContent>
    </Tooltip>
  );
}

function normalizeOptions(options: SelectOption[]): SelectOptionObject[] {
  return options.map((o) =>
    typeof o === "string" ? { label: o, value: o } : o
  );
}

function HeadingRow({ option }: { option: SelectOptionObject }) {
  return (
    <div className="flex items-center gap-2 min-w-0 flex-1 pl-1 pr-3 py-1 h-[28px] text-[11px] font-semibold text-neutral-500 dark:text-neutral-400">
      {option.icon ? (
        <span className="shrink-0 inline-flex items-center justify-center">
          {option.icon}
        </span>
      ) : null}
      <span className="truncate select-none">{option.label}</span>
    </div>
  );
}

export interface OptionItemRenderProps {
  opt: SelectOptionObject;
  isSelected: boolean;
  count?: number;
  onSelectValue: (val: string) => void;
  onWarningAction?: () => void;
  onIncrement?: () => void;
  onDecrement?: () => void;
  itemComponent: typeof CommandItem;
  itemVariant: "default" | "agent";
  itemClassName?: string;
}

interface SearchableOptionData {
  option: SelectOptionObject;
  index: number;
  heading: SelectOptionObject | null;
  labelText: string;
  displayText: string;
  valueText: string;
  combinedText: string;
}

function DefaultOptionItem({
  opt,
  isSelected,
  onSelectValue,
  onWarningAction,
  itemComponent: ItemComponent,
  itemVariant,
  itemClassName,
}: OptionItemRenderProps) {
  const handleSelect = () => {
    if (opt.isUnavailable) {
      return;
    }
    onSelectValue(opt.value);
  };
  return (
    <ItemComponent
      variant={itemVariant}
      value={`${opt.label} ${opt.value}`}
      className={clsx(
        "flex items-center justify-between gap-2 text-[13.5px] py-1.5 h-[32px]",
        opt.isUnavailable
          ? "cursor-not-allowed text-neutral-500 dark:text-neutral-500"
          : null,
        itemClassName
      )}
      onSelect={handleSelect}
    >
      <div className="flex items-center gap-2 min-w-0 flex-1">
        {opt.icon ? (
          <span className="shrink-0 inline-flex items-center justify-center">
            {opt.icon}
          </span>
        ) : null}
        <span className="truncate select-none">{opt.label}</span>
        {opt.warning ? (
          <WarningIndicator
            warning={opt.warning}
            onActivate={onWarningAction}
          />
        ) : opt.isUnavailable ? (
          <AlertTriangle className="w-3.5 h-3.5 text-amber-500 shrink-0" />
        ) : null}
      </div>
      {isSelected ? (
        <Check className="h-4 w-4 text-neutral-900 dark:text-neutral-100" />
      ) : null}
    </ItemComponent>
  );
}

const SearchableSelect = forwardRef<
  SearchableSelectHandle,
  SearchableSelectProps
>(function SearchableSelect(
  {
    options,
    value,
    onChange,
    placeholder = "Select",
    singleSelect = false,
    className,
    classNames = {},
    loading = false,
    maxTagCount: _maxTagCount,
    showSearch = true,
    disabled = false,
    countLabel = "selected",
    leftIcon,
    footer,
    itemVariant = "default",
    optionItemComponent,
    maxCountPerValue = 6,
  },
  ref
) {
  const normOptions = useMemo(() => normalizeOptions(options), [options]);
  const valueToOption = useMemo(
    () => new Map(normOptions.map((o) => [o.value, o])),
    [normOptions]
  );
  const searchableOptions = useMemo<SearchableOptionData[]>(() => {
    let activeHeading: SelectOptionObject | null = null;
    return normOptions.map((option, index) => {
      if (option.heading) {
        activeHeading = option;
      }
      const segments = [
        option.label,
        option.displayLabel,
        option.value,
      ].filter(
        (segment): segment is string => typeof segment === "string" && segment.length > 0
      );
      return {
        option,
        index,
        heading: option.heading ? option : activeHeading,
        labelText: option.label ?? "",
        displayText: option.displayLabel ?? "",
        valueText: option.value ?? "",
        combinedText: segments.join(" ").trim(),
      } satisfies SearchableOptionData;
    });
  }, [normOptions]);
  const ItemComponent = CommandItem;
  const OptionComponent: ComponentType<OptionItemRenderProps> =
    optionItemComponent ?? DefaultOptionItem;
  const resolvedMaxPerValue = Number.isFinite(maxCountPerValue)
    ? Math.max(1, Math.floor(maxCountPerValue))
    : 1;
  const allowValueCountAdjustments = !singleSelect && resolvedMaxPerValue > 1;
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement | null>(null);
  const [search, setSearch] = useState("");
  const [_recalcTick, setRecalcTick] = useState(0);
  // Popover width is fixed; no need to track trigger width
  const pendingFocusRef = useRef<string | null>(null);

  const countByValue = useMemo(() => {
    const map = new Map<string, number>();
    for (const val of value) {
      map.set(val, (map.get(val) ?? 0) + 1);
    }
    return map;
  }, [value]);
  const selectedLabels = useMemo(() => {
    const byValue = new Map(
      normOptions.map((o) => [o.value, o.label] as const)
    );
    return value.map((v) => byValue.get(v) ?? v);
  }, [normOptions, value]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  const displayContent = useMemo(() => {
    if (loading) {
      return <Skeleton className="h-4 w-18 rounded-lg" />;
    }
    if (value.length === 0) {
      return (
        <span className="text-neutral-400 truncate select-none">
          {placeholder}
        </span>
      );
    }
    // If exactly one is selected (single or multi), show icon (if any) + label
    if (value.length === 1) {
      const selectedVal = value[0];
      const selectedOpt = normOptions.find((o) => o.value === selectedVal);
      const label = selectedLabels[0];
      return (
        <span className="inline-flex items-center gap-2">
          {selectedOpt?.icon ? (
            <span className="shrink-0 inline-flex items-center justify-center">
              {selectedOpt.icon}
            </span>
          ) : null}
          <span className="truncate select-none">{label}</span>
          {selectedOpt?.warning ? (
            <WarningIndicator
              warning={selectedOpt.warning}
              onActivate={() => setOpen(false)}
            />
          ) : null}
        </span>
      );
    }
    // Multi-select with multiple items: if icons exist, show stacked icons + count
    const selectedWithIcons = value
      .map((v) => {
        const o = valueToOption.get(v);
        if (!o || !o.icon) return null;
        return { key: o.iconKey ?? o.value, icon: o.icon };
      })
      .filter(Boolean) as Array<{ key: string; icon: ReactNode }>;
    const selectedWarnings = value
      .map((v) => valueToOption.get(v)?.warning)
      .filter(Boolean) as OptionWarning[];
    const firstWarning = selectedWarnings[0];
    const aggregatedWarningTooltip = firstWarning?.tooltip ?? (
      <span>Some selected agents still need credentials in Settings.</span>
    );
    // Deduplicate by icon key (e.g., vendor) while preserving order
    const seen = new Set<string>();
    const uniqueIcons: ReactNode[] = [];
    for (const it of selectedWithIcons) {
      if (seen.has(it.key)) continue;
      seen.add(it.key);
      uniqueIcons.push(it.icon);
    }
    if (uniqueIcons.length > 0) {
      const maxIcons = 5;
      return (
        <span className="inline-flex items-center gap-2">
          <span className="flex space-x-[2px]">
            {uniqueIcons.slice(0, maxIcons).map((ico, i) => (
              <span
                key={i}
                className="inline-flex h-4 w-4 items-center justify-center overflow-hidden"
              >
                {ico}
              </span>
            ))}
          </span>
          <span className="truncate select-none">{`${value.length} ${countLabel}`}</span>
          {selectedWarnings.length ? (
            <WarningIndicator
              warning={{
                tooltip: aggregatedWarningTooltip,
                onClick: () => {
                  firstWarning?.onClick?.();
                },
              }}
              onActivate={() => setOpen(false)}
            />
          ) : null}
        </span>
      );
    }
    // Fallback: show count only
    return (
      <span className="inline-flex items-center gap-2 truncate select-none">
        <span>{`${value.length} ${countLabel}`}</span>
        {selectedWarnings.length ? (
          <WarningIndicator
            warning={{
              tooltip: aggregatedWarningTooltip,
              onClick: () => {
                firstWarning?.onClick?.();
              },
            }}
            onActivate={() => setOpen(false)}
          />
        ) : null}
      </span>
    );
  }, [
    countLabel,
    loading,
    normOptions,
    placeholder,
    selectedLabels,
    value,
    valueToOption,
  ]);

  const filteredOptions = useMemo(() => {
    const rawQuery = search.replace(/\s+/g, " ").trim();
    if (!rawQuery) {
      return normOptions;
    }
    const limit = searchableOptions.length || normOptions.length;
    const threshold = rawQuery.length <= 1 ? 0 : rawQuery.length === 2 ? 0.1 : 0.2;
    const results = fuzzysort.go(rawQuery, searchableOptions, {
      keys: ["labelText", "displayText", "valueText", "combinedText"],
      limit,
      threshold,
      scoreFn: (keysResult) => {
        const data = keysResult.obj as SearchableOptionData | undefined;
        if (!data) return 0;
        const weights = [1, 0.9, 0.5, 0.3];
        let weightedScore = 0;
        let totalWeight = 0;
        for (let i = 0; i < keysResult.length; i++) {
          const match = keysResult[i];
          const score = match && typeof match.score === "number" ? match.score : 0;
          if (score <= 0) continue;
          const weight = weights[i] ?? 0.25;
          weightedScore += score * weight;
          totalWeight += weight;
        }
        let combinedScore = totalWeight > 0 ? weightedScore / totalWeight : 0;
        const labelScore = keysResult[0]?.score ?? 0;
        const displayScore = keysResult[1]?.score ?? 0;
        if (labelScore > 0) {
          combinedScore = Math.max(combinedScore, labelScore * 1.05);
        } else if (displayScore > 0) {
          combinedScore = Math.max(combinedScore, displayScore);
        }
        if (data.option.heading) {
          combinedScore *= 0.6;
        }
        combinedScore -= data.index * 1e-6;
        return combinedScore > 0 ? combinedScore : 0;
      },
    });
    if (results.length === 0) {
      return [];
    }
    const hasNonHeadingResult = results.some((res) => !res.obj.option.heading);
    const seen = new Set<string>();
    const insertedHeadings = new Set<string>();
    const ordered: SelectOptionObject[] = [];
    for (const res of results) {
      const data = res.obj as SearchableOptionData;
      const option = data.option;
      const id = option.value ?? option.label;
      if (!id || seen.has(id)) continue;
      if (!option.heading && data.heading && data.heading !== option) {
        // Re-insert the group heading above the first matching child result
        const headingId = data.heading.value ?? data.heading.label;
        if (headingId && !insertedHeadings.has(headingId)) {
          insertedHeadings.add(headingId);
          ordered.push(data.heading);
          seen.add(headingId);
        }
      }
      if (option.heading && hasNonHeadingResult) {
        continue;
      }
      ordered.push(option);
      seen.add(id);
    }
    return ordered;
  }, [normOptions, search, searchableOptions]);

  const listRef = useRef<HTMLDivElement | null>(null);
  const rowVirtualizer = useVirtualizer({
    count: filteredOptions.length,
    getScrollElement: () => listRef.current,
    estimateSize: () => 32,
    overscan: 20,
    // Use an initial rect so the first open has a viewport size
    // even before ResizeObserver kicks in.
    initialRect: { width: 300, height: 300 },
  });

  useEffect(() => {
    if (open) {
      // Force a recompute on open after layout.
      requestAnimationFrame(() => {
        try {
          rowVirtualizer.scrollToIndex(0, { align: "start", behavior: "auto" });
        } catch {
          /* noop */
        }
        // Nudge a re-render so getVirtualItems() reflects latest measurements
        setRecalcTick((n) => n + 1);
      });
    }
  }, [open, rowVirtualizer]);

  const handleOpenAutoFocus = useCallback(
    (_event: Event) => {
      const focusValue = pendingFocusRef.current;
      if (!focusValue) {
        return;
      }
      pendingFocusRef.current = null;
      const index = filteredOptions.findIndex(
        (opt) => opt.value === focusValue
      );
      if (index === -1) {
        return;
      }
      requestAnimationFrame(() => {
        try {
          rowVirtualizer.scrollToIndex(index, {
            align: "center",
            behavior: "auto",
          });
        } catch {
          /* noop */
        }
      });
    },
    [filteredOptions, rowVirtualizer]
  );

  useImperativeHandle(
    ref,
    () => ({
      open: ({ focusValue } = {}) => {
        if (focusValue) {
          pendingFocusRef.current = focusValue;
        } else {
          pendingFocusRef.current = null;
        }
        setSearch("");
        setOpen(true);
        requestAnimationFrame(() => {
          if (focusValue && open) {
            const index = filteredOptions.findIndex(
              (opt) => opt.value === focusValue
            );
            pendingFocusRef.current = null;
            if (index !== -1) {
              try {
                rowVirtualizer.scrollToIndex(index, {
                  align: "center",
                  behavior: "auto",
                });
              } catch {
                /* noop */
              }
            }
          }
          triggerRef.current?.focus({ preventScroll: true });
        });
      },
      close: () => {
        pendingFocusRef.current = null;
        setOpen(false);
      },
    }),
    [filteredOptions, open, rowVirtualizer]
  );

  const updateValueCount = (val: string, nextCount: number) => {
    const normalized = Number.isFinite(nextCount) ? Math.round(nextCount) : 0;
    const clamped = Math.max(0, Math.min(normalized, resolvedMaxPerValue));
    const current = countByValue.get(val) ?? 0;
    if (clamped === current) return;
    const withoutVal = value.filter((existing) => existing !== val);
    const additions = Array.from({ length: clamped }, () => val);
    onChange([...withoutVal, ...additions]);
  };

  const onSelectValue = (val: string): void => {
    const selectedOption = valueToOption.get(val);
    if (selectedOption?.isUnavailable) {
      return;
    }
    // Clear search input upon selecting a value (covers mouse and keyboard selection)
    setSearch("");
    if (singleSelect) {
      onChange([val]);
      setOpen(false);
      return;
    }
    const currentCount = countByValue.get(val) ?? 0;
    if (currentCount === 0) {
      updateValueCount(val, 1);
    } else {
      updateValueCount(val, 0);
    }
  };

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <div className={clsx("inline-flex items-center", classNames.root)}>
        <Popover.Trigger asChild>
          <button
            ref={triggerRef}
            type="button"
            disabled={disabled}
            className={clsx(
              `relative inline-flex h-7 items-center rounded-md border border-neutral-200 bg-white px-2.5 pr-6 text-sm text-neutral-900 transition-colors outline-none focus:outline-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-100 aria-expanded:bg-neutral-50 dark:aria-expanded:bg-neutral-900 w-auto`,
              className,
              classNames.trigger
            )}
          >
            <span className="flex-1 min-w-0 text-left text-[13.5px] inline-flex items-center gap-1.5 pr-1 tabular-nums">
              {leftIcon ? (
                <span className="shrink-0 inline-flex items-center justify-center">
                  {leftIcon}
                </span>
              ) : null}
              {displayContent}
            </span>
            {/* Place chevron inside the button so clicking it triggers the popover */}
            <ChevronDown className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-neutral-500" />
          </button>
        </Popover.Trigger>
      </div>
      <Popover.Portal>
        <Popover.Content
          align="start"
          sideOffset={2}
          collisionPadding={{ top: 12, bottom: 12 }}
          onOpenAutoFocus={handleOpenAutoFocus}
          className={clsx(
            "z-[var(--z-modal)] rounded-md border overflow-hidden border-neutral-200 bg-white p-0 drop-shadow-xs outline-none data-[state=closed]:animate-out data-[state=closed]:fade-out-0 dark:border-neutral-800 dark:bg-neutral-950 w-[300px]",
            classNames.popover
          )}
        >
          <Command
            loop
            shouldFilter={false}
            className={clsx("text-[13.5px]", classNames.command)}
          >
            {showSearch ? (
              <CommandInput
                showIcon={false}
                placeholder="Search..."
                value={search}
                onValueChange={setSearch}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    // Clear the search box when pressing Enter
                    setSearch("");
                  }
                }}
                className={clsx("text-[13.5px] py-2", classNames.commandInput)}
              />
            ) : null}
            {loading ? (
              <div className="flex items-center justify-center py-8">
                <Loader2 className="h-5 w-5 animate-spin text-neutral-400" />
              </div>
            ) : (
              <CommandList
                ref={listRef}
                className={clsx(
                  "max-h-[18rem] overflow-y-auto",
                  classNames.commandList
                )}
              >
                {filteredOptions.length === 0 ? (
                  <CommandEmpty className={classNames.commandEmpty}>
                    <div className="px-3 py-4">
                      <span className="select-none">No options</span>
                    </div>
                  </CommandEmpty>
                ) : (
                  <CommandGroup className={classNames.commandGroup}>
                    {(() => {
                      const vItems = rowVirtualizer.getVirtualItems();
                      if (vItems.length === 0 && filteredOptions.length > 0) {
                        const fallback = filteredOptions.slice(0, 12);
                        return (
                          <div>
                            {fallback.map((opt) => {
                              const count = countByValue.get(opt.value) ?? 0;
                              const isSelected = count > 0;
                              const increment = allowValueCountAdjustments
                                ? () => updateValueCount(opt.value, count + 1)
                                : undefined;
                              const decrement = allowValueCountAdjustments
                                ? () => updateValueCount(opt.value, count - 1)
                                : undefined;
                              if (opt.heading) {
                                return (
                                  <div
                                    key={`fallback-${opt.value ?? opt.label}`}
                                  >
                                    <HeadingRow option={opt} />
                                  </div>
                                );
                              }
                              return (
                                <OptionComponent
                                  key={`fallback-${opt.value ?? opt.label}`}
                                  opt={opt}
                                  isSelected={isSelected}
                                  count={
                                    allowValueCountAdjustments
                                      ? count
                                      : undefined
                                  }
                                  onSelectValue={onSelectValue}
                                  onWarningAction={() => setOpen(false)}
                                  onIncrement={increment}
                                  onDecrement={decrement}
                                  itemComponent={ItemComponent}
                                  itemVariant={itemVariant}
                                  itemClassName={classNames.commandItem}
                                />
                              );
                            })}
                          </div>
                        );
                      }
                      return (
                        <div
                          style={{
                            height: rowVirtualizer.getTotalSize(),
                            position: "relative",
                          }}
                        >
                          {vItems.map((vr) => {
                            const opt = filteredOptions[vr.index]!;
                            const count = countByValue.get(opt.value) ?? 0;
                            const isSelected = count > 0;
                            const increment = allowValueCountAdjustments
                              ? () => updateValueCount(opt.value, count + 1)
                              : undefined;
                            const decrement = allowValueCountAdjustments
                              ? () => updateValueCount(opt.value, count - 1)
                              : undefined;
                            return (
                              <div
                                key={opt.value ?? `${vr.index}`}
                                data-index={vr.index}
                                ref={rowVirtualizer.measureElement}
                                style={{
                                  position: "absolute",
                                  top: 0,
                                  left: 0,
                                  width: "100%",
                                  transform: `translateY(${vr.start}px)`,
                                }}
                              >
                                {opt.heading ? (
                                  <HeadingRow option={opt} />
                                ) : (
                                  <OptionComponent
                                    opt={opt}
                                    isSelected={isSelected}
                                    count={
                                      allowValueCountAdjustments
                                        ? count
                                        : undefined
                                    }
                                    onSelectValue={onSelectValue}
                                    onWarningAction={() => setOpen(false)}
                                    onIncrement={increment}
                                    onDecrement={decrement}
                                    itemComponent={ItemComponent}
                                    itemVariant={itemVariant}
                                    itemClassName={classNames.commandItem}
                                  />
                                )}
                              </div>
                            );
                          })}
                        </div>
                      );
                    })()}
                  </CommandGroup>
                )}
              </CommandList>
            )}
          </Command>
          {footer ? (
            <div
              className={clsx(
                "border-t border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 min-h-[40.5px]",
                classNames.footer
              )}
            >
              {footer}
            </div>
          ) : null}
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
});

export { SearchableSelect };
export default SearchableSelect;
