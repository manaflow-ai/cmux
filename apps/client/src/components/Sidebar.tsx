import { TaskTree, type TaskWithRuns } from "@/components/TaskTree";
import { TaskTreeSkeleton } from "@/components/TaskTreeSkeleton";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { isElectron } from "@/lib/electron";
import { type Doc } from "@cmux/convex/dataModel";
import { Link } from "@tanstack/react-router";
import { Plus } from "lucide-react";
import {
  type CSSProperties,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import CmuxLogo from "./logo/cmux-logo";

interface SidebarProps {
  tasks: Doc<"tasks">[] | undefined;
  tasksWithRuns: TaskWithRuns[];
  teamSlugOrId: string;
}

export function Sidebar({ tasks, tasksWithRuns, teamSlugOrId }: SidebarProps) {
  const DEFAULT_WIDTH = 256;
  const MIN_WIDTH = 200;
  const MAX_WIDTH = 600;

  const containerRef = useRef<HTMLDivElement | null>(null);
  const containerLeftRef = useRef<number>(0);
  const rafIdRef = useRef<number | null>(null);
  const [width, setWidth] = useState<number>(() => {
    const stored = localStorage.getItem("sidebarWidth");
    const parsed = stored ? Number.parseInt(stored, 10) : DEFAULT_WIDTH;
    if (Number.isNaN(parsed)) return DEFAULT_WIDTH;
    return Math.min(Math.max(parsed, MIN_WIDTH), MAX_WIDTH);
  });
  const [isResizing, setIsResizing] = useState(false);

  const { expandTaskIds } = useExpandTasks();

  useEffect(() => {
    localStorage.setItem("sidebarWidth", String(width));
  }, [width]);

  const onMouseMove = useCallback((e: MouseEvent) => {
    // Batch width updates to once per animation frame to reduce layout thrash
    if (rafIdRef.current != null) return;
    rafIdRef.current = window.requestAnimationFrame(() => {
      rafIdRef.current = null;
      const containerLeft = containerLeftRef.current;
      const clientX = e.clientX;
      const newWidth = Math.min(
        Math.max(clientX - containerLeft, MIN_WIDTH),
        MAX_WIDTH
      );
      setWidth(newWidth);
    });
  }, []);

  const stopResizing = useCallback(() => {
    setIsResizing(false);
    document.body.style.cursor = "";
    document.body.classList.remove("select-none");
    document.body.classList.remove("cmux-sidebar-resizing");
    if (rafIdRef.current != null) {
      cancelAnimationFrame(rafIdRef.current);
      rafIdRef.current = null;
    }
    // Restore iframe pointer events
    const iframes = Array.from(document.querySelectorAll("iframe"));
    for (const el of iframes) {
      if (el instanceof HTMLIFrameElement) {
        const prev = el.dataset.prevPointerEvents;
        if (prev !== undefined) {
          if (prev === "__unset__") {
            el.style.removeProperty("pointer-events");
          } else {
            el.style.pointerEvents = prev;
          }
          delete el.dataset.prevPointerEvents;
        } else {
          // Fallback to clearing
          el.style.removeProperty("pointer-events");
        }
      }
    }
    window.removeEventListener("mousemove", onMouseMove);
    window.removeEventListener("mouseup", stopResizing);
  }, [onMouseMove]);

  const startResizing = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      e.preventDefault();
      setIsResizing(true);
      document.body.style.cursor = "col-resize";
      document.body.classList.add("select-none");
      document.body.classList.add("cmux-sidebar-resizing");
      // Snapshot the container's left position so we don't force layout on every move
      if (containerRef.current) {
        const rect = containerRef.current.getBoundingClientRect();
        containerLeftRef.current = rect.left;
      }
      // Disable pointer events on all iframes so dragging works over them
      const iframes = Array.from(document.querySelectorAll("iframe"));
      for (const el of iframes) {
        if (el instanceof HTMLIFrameElement) {
          const current = el.style.pointerEvents;
          el.dataset.prevPointerEvents = current ? current : "__unset__";
          el.style.pointerEvents = "none";
        }
      }
      window.addEventListener("mousemove", onMouseMove);
      window.addEventListener("mouseup", stopResizing);
    },
    [onMouseMove, stopResizing]
  );

  useEffect(() => {
    return () => {
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", stopResizing);
    };
  }, [onMouseMove, stopResizing]);

  const resetWidth = useCallback(() => setWidth(DEFAULT_WIDTH), []);


  return (
    <div
      ref={containerRef}
      className="relative bg-neutral-50 dark:bg-black flex flex-col shrink-0 h-dvh grow"
      style={{
        width: `${width}px`,
        minWidth: `${width}px`,
        maxWidth: `${width}px`,
        userSelect: isResizing ? ("none" as const) : undefined,
      }}
    >
      <div
        className="h-[38px] flex items-center pl-3 pr-1.5 shrink-0"
        style={{ WebkitAppRegion: "drag" } as CSSProperties}
      >
        {isElectron && <div className="w-[68px]"></div>}
        <Link
          to="/$teamSlugOrId/dashboard"
          params={{ teamSlugOrId }}
          className="flex items-center gap-2 select-none cursor-pointer"
          style={{ WebkitAppRegion: "no-drag" } as CSSProperties}
        >
          {/* <Terminals */}
          <CmuxLogo height={32} />
        </Link>
        <div className="grow"></div>
        <Link
          to="/$teamSlugOrId/dashboard"
          params={{ teamSlugOrId }}
          className="w-[25px] h-[25px] border border-neutral-200 dark:border-neutral-800 hover:bg-neutral-100 dark:hover:bg-neutral-900 rounded-lg flex items-center justify-center transition-colors cursor-default"
          title="New task"
          style={{ WebkitAppRegion: "no-drag" } as CSSProperties}
        >
          <Plus
            className="w-4 h-4 text-neutral-700 dark:text-neutral-300"
            aria-hidden="true"
          />
        </Link>
      </div>
      <nav className="grow flex flex-col overflow-hidden">
        <div className="flex-1 overflow-y-auto">
          <div className="pl-3 py-1">
            <div className="flex items-center px-1 py-1">
              <span className="text-[10px] font-medium text-neutral-500 dark:text-neutral-500 uppercase tracking-[-0.005em] select-none">
                Recent Tasks
              </span>
            </div>
            <div className="space-y-px">
              {tasks === undefined ? (
                <TaskTreeSkeleton count={5} />
              ) : tasksWithRuns.length > 0 ? (
                tasksWithRuns.map((task) => (
                  <TaskTree
                    key={task._id}
                    task={task}
                    defaultExpanded={expandTaskIds?.includes(task._id) ?? false}
                    teamSlugOrId={teamSlugOrId}
                  />
                ))
              ) : (
                <p className="px-2 py-1.5 text-xs text-center text-neutral-500 dark:text-neutral-400 select-none">
                  No recent tasks
                </p>
              )}
            </div>
          </div>
        </div>
      </nav>

      <div className="pb-2 shrink-0 flex flex-col">
        <Link
          to="/$teamSlugOrId/environments"
          params={{ teamSlugOrId }}
          className="flex items-center px-7 py-2 text-sm text-neutral-700 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors select-none cursor-default"
        >
          <svg
            className="w-4 h-4 mr-3 text-neutral-500"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M3 7h18M3 12h18M3 17h18"
            />
          </svg>
          Environments
        </Link>
        <a
          href="https://github.com/manaflow-ai/cmux/issues/new"
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center px-7 py-2 text-sm text-neutral-700 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors select-none cursor-pointer"
        >
          <svg
            className="w-4 h-4 mr-3 text-neutral-500"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
            />
          </svg>
          Feedback
        </a>
        <Link
          to="/$teamSlugOrId/settings"
          params={{ teamSlugOrId }}
          className="flex items-center px-7 py-2 text-sm text-neutral-700 dark:text-neutral-300 hover:bg-neutral-100 dark:hover:bg-neutral-800 transition-colors select-none cursor-default"
        >
          <svg
            className="w-4 h-4 mr-3 text-neutral-500"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
            />
          </svg>
          Settings
        </Link>
      </div>

      {/* Resize handle */}
      <div
        role="separator"
        aria-orientation="vertical"
        title="Drag to resize"
        onMouseDown={startResizing}
        onDoubleClick={resetWidth}
        className="absolute top-0 right-0 h-full cursor-col-resize"
        style={
          {
            // Invisible, but with a comfortable hit area
            width: "10px",
            marginRight: "-5px",
            background: "transparent",
            // background: "red",
            zIndex: 10000,
          } as CSSProperties
        }
      />
    </div>
  );
}
