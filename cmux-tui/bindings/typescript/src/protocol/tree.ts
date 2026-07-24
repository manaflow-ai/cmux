import type { Id, Size, SplitDirection } from "./common.js";

/** The canonical pane split tree. */
export type Layout =
  | { type: "leaf"; pane: Id }
  | {
      type: "split";
      /** Stable split id. Absent only when connected to a pre-v8 server. */
      split?: Id;
      dir: SplitDirection;
      ratio: number;
      a: Layout;
      b: Layout;
    }
  | { type: "stack"; panes: [Id, ...Id[]]; expanded: Id };

/** A declarative split tree used by `apply-layout`. */
export type DeclarativeLayout =
  | { type: "leaf"; cwd?: string | null; command?: string[] | null }
  | {
      type: "split";
      dir: SplitDirection;
      ratio: number;
      a: DeclarativeLayout;
      b: DeclarativeLayout;
    }
  | { type: "stack"; panes: [Id, ...Id[]]; expanded: Id };

/** A live PTY or browser tab. */
export interface Tab {
  surface: Id;
  kind: "pty" | "browser";
  browser_source: "external" | "launched" | null;
  name: string | null;
  title: string;
  size: Size | null;
  dead: boolean;
}

/** A live pane containing tabs. */
export interface LivePane {
  id: Id;
  name: string | null;
  active_tab: number;
  focused_at?: number;
  tabs: Tab[];
}

/** A defensive placeholder for a tree leaf whose pane state is missing. */
export interface DeadPane {
  id: Id;
  dead: true;
}

/** A pane in a tree snapshot. */
export type Pane = LivePane | DeadPane;

/** A named split-tree screen. */
export interface Screen {
  id: Id;
  name: string | null;
  active: boolean;
  active_pane: Id;
  zoomed_pane: Id | null;
  layout: Layout;
  panes: Pane[];
}

/** A workspace containing one or more screens. */
export interface Workspace {
  id: Id;
  /** Stable registry key. Absent without the `workspace-registry-v1` capability. */
  key?: string;
  name: string;
  active: boolean;
  screens: Screen[];
}

/** The complete workspace, screen, pane, tab, and layout snapshot. */
export interface Tree {
  /** Ordered-registry revision. Absent without the `workspace-registry-v1` capability. */
  workspace_revision?: number;
  /** Live pane-membership revision. Absent on older servers. */
  pane_revision?: number;
  workspaces: Workspace[];
}
