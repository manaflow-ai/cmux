import { env } from "@/lib/utils/www-env";
import {
  verifyTaskRunToken as verifyTaskRunTokenShared,
  type TaskRunTokenPayload,
} from "@cmux/shared/task-run-token";

export type { TaskRunTokenPayload };

export function verifyTaskRunToken(token: string): Promise<TaskRunTokenPayload> {
  return verifyTaskRunTokenShared(token, env.CMUX_TASK_RUN_JWT_SECRET);
}
