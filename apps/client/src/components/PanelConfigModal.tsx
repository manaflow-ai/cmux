import { useState } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import type { LucideIcon } from "lucide-react";
import { X, RotateCcw, GripVertical, MessageSquare, Code2, TerminalSquare, Globe2, GitCompare, Plus, Grid2x2, Columns2, Rows2, PanelsLeftBottom, PanelsRightBottom, PanelsTopLeft, Trash2, Square, Sparkles } from "lucide-react";
import clsx from "clsx";
import type { PanelConfig, PanelType, LayoutMode, PanelPosition } from "@/lib/panel-config";
import { PANEL_LABELS, DEFAULT_PANEL_CONFIG, LAYOUT_LABELS, LAYOUT_DESCRIPTIONS, getActivePanelPositions, getAvailablePanels, removePanelFromAllPositions } from "@/lib/panel-config";

interface PanelConfigModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  config: PanelConfig;
  onChange: (config: PanelConfig) => void;
}

const PANEL_ICONS_MAP: Record<PanelType, LucideIcon> = {
  chat: MessageSquare,
  workspace: Code2,
  terminal: TerminalSquare,
  browser: Globe2,
  gitDiff: GitCompare,
  claims: Sparkles,
};

interface LayoutIconConfig {
  Icon: LucideIcon;
  className?: string;
}

const LAYOUT_ICON_CONFIGS: Record<LayoutMode, LayoutIconConfig> = {
  "single-panel": { Icon: Square },
  "four-panel": { Icon: Grid2x2 },
  "two-horizontal": { Icon: Columns2 },
  "two-vertical": { Icon: Rows2 },
  "three-left": { Icon: PanelsLeftBottom },
  "three-right": { Icon: PanelsRightBottom },
  "three-top": { Icon: PanelsTopLeft },
  "three-bottom": { Icon: PanelsTopLeft, className: "rotate-180" },
};

export function PanelConfigModal({ open, onOpenChange, config, onChange }: PanelConfigModalProps) {
  const [draggedType, setDraggedType] = useState<PanelType | null>(null);
  const [draggedFrom, setDraggedFrom] = useState<PanelPosition | null>(null);
  const [showAddMenu, setShowAddMenu] = useState<PanelPosition | null>(null);

  const activePanelPositions = getActivePanelPositions(config.layoutMode);
  const availablePanels = getAvailablePanels(config);
  const currentLayout = config.layouts[config.layoutMode];

  const handleDragStart = (type: PanelType, position: PanelPosition) => {
    setDraggedType(type);
    setDraggedFrom(position);
  };

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  const handleDrop = (targetPosition: PanelPosition) => {
    if (!draggedType || !draggedFrom) return;

    // If dropping on the same position, do nothing
    if (draggedFrom === targetPosition) {
      setDraggedType(null);
      setDraggedFrom(null);
      return;
    }

    // Swap the panels in current layout
    const targetType = currentLayout[targetPosition];
    const newConfig = {
      ...config,
      layouts: {
        ...config.layouts,
        [config.layoutMode]: {
          ...currentLayout,
          [targetPosition]: draggedType,
          [draggedFrom]: targetType,
        },
      },
    };

    onChange(newConfig);
    setDraggedType(null);
    setDraggedFrom(null);
  };

  const handleReset = () => {
    onChange(DEFAULT_PANEL_CONFIG);
  };

  const handleLayoutModeChange = (layoutMode: LayoutMode) => {
    onChange({ ...config, layoutMode });
  };

  const handleRemovePanel = (position: PanelPosition) => {
    const newConfig = {
      ...config,
      layouts: {
        ...config.layouts,
        [config.layoutMode]: {
          ...currentLayout,
          [position]: null,
        },
      },
    };
    onChange(newConfig);
  };

  const handleAddPanelToPosition = (position: PanelPosition, panelType: PanelType) => {
    // Remove the panel from all positions first to prevent duplicates
    const newConfigWithoutPanel = removePanelFromAllPositions(config, panelType);
    // Then add it to the target position
    const updatedLayout = newConfigWithoutPanel.layouts[config.layoutMode];
    const newConfig = {
      ...newConfigWithoutPanel,
      layouts: {
        ...newConfigWithoutPanel.layouts,
        [config.layoutMode]: {
          ...updatedLayout,
          [position]: panelType,
        },
      },
    };
    onChange(newConfig);
    setShowAddMenu(null);
  };

  const renderPanel = (position: PanelPosition, label: string) => {
    const isActive = activePanelPositions.includes(position);
    if (!isActive) {
      return (
        <div className="flex h-32 items-center justify-center rounded-lg border-2 border-dashed border-neutral-200 bg-neutral-100 opacity-50 dark:border-neutral-800 dark:bg-neutral-950">
          <span className="text-xs text-neutral-400 dark:text-neutral-600">Inactive</span>
        </div>
      );
    }

    const panelType = currentLayout[position];
    const panelLabel = panelType ? PANEL_LABELS[panelType] : "Empty";
    const PanelIcon = panelType ? PANEL_ICONS_MAP[panelType] : Plus;
    const isDragging = draggedFrom === position;
    const isDraggable = Boolean(panelType);
    const isAddMenuOpen = showAddMenu === position;

    const handlePanelDragStart = () => {
      if (!panelType) {
        return;
      }
      handleDragStart(panelType, position);
    };

    return (
      <div
        draggable={isDraggable}
        onDragStart={isDraggable ? handlePanelDragStart : undefined}
        onDragOver={handleDragOver}
        onDrop={() => handleDrop(position)}
        onDragEnd={() => {
          setDraggedType(null);
          setDraggedFrom(null);
        }}
        className={clsx(
          "group relative flex h-32 flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed transition-all",
          isDraggable ? "cursor-move" : "cursor-default",
          isDragging
            ? "border-neutral-400 bg-neutral-100/50 opacity-50 dark:border-neutral-600 dark:bg-neutral-800/50"
            : "border-neutral-300 bg-neutral-50 hover:border-neutral-400 hover:bg-neutral-100 dark:border-neutral-700 dark:bg-neutral-900 dark:hover:border-neutral-600 dark:hover:bg-neutral-800",
        )}
      >
        <GripVertical
          className={clsx(
            "absolute top-2 left-2 size-4 text-neutral-400 transition-opacity dark:text-neutral-500",
            isDraggable ? "opacity-100" : "opacity-0"
          )}
        />

        {/* Remove button */}
        {panelType && (
          <button
            type="button"
            onClick={(e) => {
              e.stopPropagation();
              handleRemovePanel(position);
            }}
            className="absolute top-2 right-2 size-6 flex items-center justify-center rounded bg-neutral-200 text-neutral-600 opacity-0 group-hover:opacity-100 hover:bg-red-100 hover:text-red-600 dark:bg-neutral-700 dark:text-neutral-400 dark:hover:bg-red-900 dark:hover:text-red-400 transition-all"
            aria-label="Remove panel"
          >
            <Trash2 className="size-3.5" />
          </button>
        )}

        <div className="text-xs font-medium uppercase tracking-wide text-neutral-500 dark:text-neutral-400">
          {label}
        </div>
        <div className="flex flex-col items-center gap-1">
          {panelType ? (
            <div
              className="flex size-10 items-center justify-center rounded-full bg-neutral-200 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200"
            >
              <PanelIcon className="size-5" />
            </div>
          ) : (
            <div className="relative">
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setShowAddMenu(isAddMenuOpen ? null : position);
                }}
                className="flex size-10 items-center justify-center rounded-full bg-neutral-200 text-neutral-400 hover:bg-neutral-300 hover:text-neutral-700 dark:bg-neutral-800 dark:text-neutral-500 dark:hover:bg-neutral-700 dark:hover:text-neutral-300 transition-colors"
              >
                <Plus className="size-5" />
              </button>

              {isAddMenuOpen && availablePanels.length > 0 && (
                <>
                  <div
                    className="fixed inset-0 z-[100]"
                    onClick={() => setShowAddMenu(null)}
                  />
                  <div className="absolute left-1/2 -translate-x-1/2 top-full z-[101] mt-2 w-40 rounded-lg border border-neutral-200 bg-white shadow-lg dark:border-neutral-700 dark:bg-neutral-800">
                    {availablePanels.map((availablePanelType) => {
                      const Icon = PANEL_ICONS_MAP[availablePanelType];
                      return (
                        <button
                          key={availablePanelType}
                          type="button"
                          onClick={(e) => {
                            e.stopPropagation();
                            handleAddPanelToPosition(position, availablePanelType);
                          }}
                          className="flex w-full items-center gap-3 px-3 py-2 text-left text-sm text-neutral-700 hover:bg-neutral-100 dark:text-neutral-200 dark:hover:bg-neutral-700 first:rounded-t-lg last:rounded-b-lg transition-colors"
                        >
                          <Icon className="size-4" />
                          {PANEL_LABELS[availablePanelType]}
                        </button>
                      );
                    })}
                  </div>
                </>
              )}
            </div>
          )}
          <span
            className={clsx(
              "text-sm font-medium",
              panelType ? "text-neutral-800 dark:text-neutral-100" : "text-neutral-500 dark:text-neutral-400"
            )}
          >
            {panelLabel}
          </span>
        </div>
      </div>
    );
  };

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[var(--z-global-blocking)] bg-black/50 backdrop-blur-sm" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-[var(--z-global-blocking)] w-full max-w-2xl -translate-x-1/2 -translate-y-1/2 rounded-lg border border-neutral-200 bg-white p-6 shadow-xl focus:outline-none dark:border-neutral-800 dark:bg-neutral-900">
          {/* Header */}
          <div className="mb-6 flex items-center justify-between">
            <Dialog.Title className="text-lg font-semibold text-neutral-900 dark:text-white">
              Panel Layout Settings
            </Dialog.Title>
            <Dialog.Close asChild>
              <button
                type="button"
                className="rounded-md p-1 text-neutral-400 hover:bg-neutral-100 hover:text-neutral-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-neutral-400/40 dark:hover:bg-neutral-800 dark:hover:text-white"
                aria-label="Close"
              >
                <X className="size-5" />
              </button>
            </Dialog.Close>
          </div>

          {/* Description */}
          <Dialog.Description className="mb-6 text-sm text-neutral-600 dark:text-neutral-400">
            Choose a layout mode and drag and drop panels to customize your workspace. Your configuration will be saved automatically.
          </Dialog.Description>

          {/* Layout Mode Selection */}
          <div className="mb-6">
            <h3 className="mb-3 text-sm font-semibold text-neutral-900 dark:text-white">
              Layout Mode
            </h3>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {(Object.keys(LAYOUT_LABELS) as LayoutMode[]).map((layoutMode) => {
                const { Icon: LayoutIcon, className: iconClassName } = LAYOUT_ICON_CONFIGS[layoutMode];
                const isSelected = config.layoutMode === layoutMode;
                return (
                  <button
                    key={layoutMode}
                    type="button"
                    onClick={() => handleLayoutModeChange(layoutMode)}
                    className={clsx(
                      "flex flex-col items-center gap-2 rounded-lg border-2 p-3 transition-all",
                      isSelected
                        ? "border-neutral-900 bg-neutral-900 text-white dark:border-neutral-100 dark:bg-neutral-100 dark:text-neutral-900"
                        : "border-neutral-200 bg-white text-neutral-700 hover:border-neutral-300 hover:bg-neutral-50 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:border-neutral-600 dark:hover:bg-neutral-800"
                    )}
                    title={LAYOUT_DESCRIPTIONS[layoutMode]}
                  >
                    <LayoutIcon className={clsx("size-5", iconClassName)} />
                    <span className="text-xs font-medium text-center leading-tight">
                      {LAYOUT_LABELS[layoutMode].replace(/\s*\(.*?\)\s*/g, "")}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          {/* Grid Preview */}
          <div className="mb-6">
            <h3 className="mb-3 text-sm font-semibold text-neutral-900 dark:text-white">
              Panel Configuration
            </h3>
            <div className="grid grid-cols-2 gap-4">
              {renderPanel("topLeft", "Top Left")}
              {renderPanel("topRight", "Top Right")}
              {renderPanel("bottomLeft", "Bottom Left")}
              {renderPanel("bottomRight", "Bottom Right")}
            </div>
          </div>

          {/* Actions */}
          <div className="flex items-center justify-between border-t border-neutral-200 pt-4 dark:border-neutral-800">
            <button
              type="button"
              onClick={handleReset}
              className="flex items-center gap-2 rounded-md border border-neutral-300 px-4 py-2 text-sm font-medium text-neutral-700 hover:bg-neutral-50 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-800"
            >
              <RotateCcw className="size-4" />
              Reset to Default
            </button>
            <Dialog.Close asChild>
              <button
                type="button"
                className="rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
              >
                Done
              </button>
            </Dialog.Close>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
