import type { Id } from "@cmux/convex/dataModel";
import type { TaskError, TaskStarted } from "@cmux/shared";
import type { CmuxSocket } from "@/contexts/socket/types";

interface TaskLifecycleOptions {
  onStarted?: (payload: TaskStarted) => void;
  onFailed?: (payload: TaskError) => void;
}

export function attachTaskLifecycleListeners(
  socket: CmuxSocket | null,
  taskId: Id<"tasks">,
  options: TaskLifecycleOptions,
) {
  if (!socket) return;

  const handleStarted = (payload: TaskStarted) => {
    if (payload.taskId !== taskId) {
      return;
    }
    cleanup();
    options.onStarted?.(payload);
  };

  const handleFailed = (payload: TaskError) => {
    if (payload.taskId !== taskId) {
      return;
    }
    cleanup();
    options.onFailed?.(payload);
  };

  const cleanup = () => {
    socket.off("task-started", handleStarted);
    socket.off("task-failed", handleFailed);
  };

  socket.on("task-started", handleStarted);
  socket.on("task-failed", handleFailed);

  return cleanup;
}
